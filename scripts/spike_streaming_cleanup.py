#!/usr/bin/env python
"""Spike: would cleaning text WHILE the user is still speaking cut key-up latency?

Replays real dictations from ~/.pomvox/history.db as if they had arrived
sentence by sentence, cleans the "settled" part ahead of time and only the
tail at key-up, splices the two, and compares against cleaning the whole
transcript at once — the way Pomvox works today.

Two numbers decide the go/no-go:
  * diff rate — how often the spliced text differs from the whole-transcript
    text, and by how much (word-level similarity). A high rate means the model
    needs context across the split (cross-sentence self-corrections are the
    known hazard) and the design must carry it.
  * key-up latency — the tail's cleanup time vs the whole transcript's. The
    settled part's cleanup is hidden behind the speaker, so the tail is what
    the user waits for.

Scheme measured here (the simplest that could work):
  blocks = sentences grouped so each block is >= MIN_BLOCK_CHARS; every block
  but the last is "settled" and cleaned on its own; the last block is the tail.
  Variant B feeds the previous block as leading context and keeps only the
  part of the output that aligns after it (uses the model to see across the
  seam).

    uv run python scripts/spike_streaming_cleanup.py --limit 30 --min-chars 400

Loads the shipped v3 from the LOCAL Hugging Face snapshot only (no download,
no cache writes — see the adapter-trap note in eval_cleanup_v2.py).
"""
import argparse, difflib, glob, re, sqlite3, statistics, time
from pathlib import Path

from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

MIN_BLOCK_CHARS = 200
SENT = re.compile(r"(?<=[.!?])\s+")


def sentences(raw):
    return [s for s in SENT.split(raw.strip()) if s]


def blocks(raw, min_chars=MIN_BLOCK_CHARS):
    out, cur = [], ""
    for s in sentences(raw):
        cur = (cur + " " + s).strip()
        if len(cur) >= min_chars:
            out.append(cur); cur = ""
    if cur:
        if out: out[-1] = out[-1] + " " + cur
        else: out.append(cur)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--min-chars", type=int, default=400)
    a = ap.parse_args()

    snap = glob.glob(str(Path.home() / ".cache/huggingface/hub/models--abhiram3040--simplewords-dictation-cleanup-v3/snapshots/*"))[0]
    system = (Path(snap) / "system_v2.txt").read_text().strip()
    model, tok = load(snap)
    sampler = make_sampler(temp=0.0)

    def clean(raw):
        prompt = tok.apply_chat_template(
            [{"role": "user", "content": f"{system}\n\n{raw}"}],
            add_generation_prompt=True, enable_thinking=False, tokenize=False)
        t0 = time.time()
        out = generate(model, tok, prompt=prompt, max_tokens=1024, sampler=sampler).strip()
        return out, time.time() - t0

    con = sqlite3.connect(f"file:{Path.home()}/.pomvox/history.db?mode=ro", uri=True)
    rows = con.execute(
        "select raw_text from history where cleanup_status='ok' and length(raw_text)>=? "
        "order by ts desc limit ?", (a.min_chars, a.limit)).fetchall()
    clean("hello there")  # warm

    stats = {"A": [], "B": []}
    for i, (raw,) in enumerate(rows):
        bl = blocks(raw)
        if len(bl) < 2:
            continue
        whole, t_whole = clean(raw)

        # Variant A: independent blocks; tail = last block.
        settled = [clean(b)[0] for b in bl[:-1]]
        tail, t_tail = clean(bl[-1])
        spliced_a = " ".join(settled + [tail])

        # Variant B: each block cleaned with the previous RAW block as context,
        # keep the output after the best alignment of the context's cleaned form.
        parts_b, t_tail_b = [], 0.0
        for j, b in enumerate(bl):
            if j == 0:
                out, dt = clean(b); parts_b.append(out); continue
            ctx = bl[j - 1]
            out, dt = clean(ctx + " " + b)
            # Drop the context's share: align on the previously cleaned block.
            prev = parts_b[-1]
            m = difflib.SequenceMatcher(None, prev, out).find_longest_match(0, len(prev), 0, len(out))
            cut = m.b + m.size if m.size > 20 else len(out) // 2
            parts_b.append(out[cut:].strip())
            if j == len(bl) - 1: t_tail_b = dt
        spliced_b = " ".join(parts_b)

        for name, sp, tt in (("A", spliced_a, t_tail), ("B", spliced_b, t_tail_b)):
            sim = difflib.SequenceMatcher(None, whole.split(), sp.split()).ratio()
            stats[name].append((sim, t_whole, tt))
            print(f"[{i:02d}] {name} chars={len(raw):5d} blocks={len(bl)} whole={t_whole:5.1f}s "
                  f"tail={tt:4.1f}s  sim={sim:.3f}{'  IDENTICAL' if sim == 1.0 else ''}")
        if stats["A"][-1][0] < 0.9:
            print("      WHOLE :", whole[:300].replace("\n", " "))
            print("      SPLICE:", spliced_a[:300].replace("\n", " "))

    for name in ("A", "B"):
        s = stats[name]
        if not s: continue
        sims = [x[0] for x in s]
        print(f"\n=== Variant {name}: {len(s)} dictations ===")
        print(f"identical: {sum(1 for x in sims if x == 1.0)}/{len(s)}   sim>=0.95: {sum(1 for x in sims if x >= 0.95)}/{len(s)}   "
              f"median sim {statistics.median(sims):.3f}  min {min(sims):.3f}")
        print(f"key-up latency: whole p50 {statistics.median(x[1] for x in s):.1f}s -> tail p50 "
              f"{statistics.median(x[2] for x in s):.1f}s  ({statistics.median(x[1]/max(x[2],0.01) for x in s):.1f}x)")


if __name__ == "__main__":
    main()
