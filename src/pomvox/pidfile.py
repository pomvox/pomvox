"""Pidfile mutual exclusion: one event tap / mic at a time across engines.

The native Swift engine (Pomvox.app) and the Python engine must never both hold
a CGEventTap or the microphone. A single file ``~/.pomvox/engine.pid`` records
the current owner; whoever is about to arm an event tap acquires it first and
refuses if a live *other* engine already holds it.

The file format is the cross-engine contract (mirrored in
``Pomvox/Sources/Engine/Pidfile.swift``): line 1 is the pid, line 2 the owner
name (``python`` | ``native``), line 3 the owner's executable path.

Line 3 exists because **a pid is not an identity**. It is a small integer the
kernel hands back out, and Pomvox is a login item — it starts early and gets a
*low* pid, exactly the range other early-boot daemons are assigned after a
reboot. A liveness test alone (``kill(pid, 0)``) therefore reports a stale
pidfile as a live holder essentially forever: seen in the field 2026-08-27,
where ``985 / native`` survived a reboot, pid 985 came back as ``usernoted``,
and the engine refused to arm on every launch with no way for the user to
recover but to delete the file by hand. Matching the recorded path against what
the pid is *actually* running rejects that case.

The decision (:func:`owner_is_live`) is pure and unit-tested; only
:func:`identity` touches the OS.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

PIDFILE = Path.home() / ".pomvox" / "engine.pid"


@dataclass(frozen=True)
class Owner:
    pid: int
    name: str  # "python" | "native"
    exec_path: str | None = None  # None on a legacy 2-line file


class Liveness(Enum):
    """What the OS says about a pid right now."""

    DEAD = "dead"
    RUNNING = "running"
    UNVERIFIABLE = "unverifiable"  # alive, but owned by another user


@dataclass(frozen=True)
class Identity:
    liveness: Liveness
    exec_path: str | None = None


def _pid_alive(pid: int) -> bool:
    """True if a process with *pid* exists (POSIX ``kill(pid, 0)``)."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by another user
    return True


def _exec_path(pid: int) -> str | None:
    """The executable *pid* is running, via ``ps``. None if it can't be read."""
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    path = out.stdout.strip()
    return path or None


def identity(pid: int) -> Identity:
    """Liveness plus, when we're allowed to see it, the executable path."""
    if not _pid_alive(pid):
        return Identity(Liveness.DEAD)
    path = _exec_path(pid)
    if path is None:
        return Identity(Liveness.UNVERIFIABLE)
    return Identity(Liveness.RUNNING, path)


def current_exec_path() -> str:
    """What we record for ourselves — read the same way we read other pids, so
    the value is byte-identical to what a later probe on this pid returns."""
    return _exec_path(os.getpid()) or "python"


# --- the decision (pure) ----------------------------------------------------


def legacy_path_could_be_engine(path: str, name: str) -> bool:
    """Shape test for pidfiles written before the exec-path line existed."""
    base = os.path.basename(path).lower()
    if name == "native":
        return base == "pomvox"
    if name == "python":
        # Console script, ``uv run``, or a bare interpreter (python, python3.12).
        return base in ("pomvox", "uv") or base.startswith("python")
    return False


def owner_is_live(owner: Owner, ident: Identity) -> bool:
    """Is the process behind ``owner.pid`` still the one that wrote the pidfile?

    A recorded exec path is matched exactly. A legacy 2-line file has nothing to
    match, so it falls back to a shape test: a path that could plausibly be the
    engine named in the file is trusted, anything else is treated as a recycled
    pid. Being wrong in the trusting direction only costs a spurious "blocked";
    being wrong the other way would let two engines share the mic.
    """
    if ident.liveness is Liveness.DEAD:
        return False
    if ident.liveness is Liveness.UNVERIFIABLE:
        # Another user's process: we can't disprove it, so we mustn't steal it.
        return True
    actual = ident.exec_path or ""
    if owner.exec_path is not None:
        return owner.exec_path == actual
    return legacy_path_could_be_engine(actual, owner.name)


# --- file IO ----------------------------------------------------------------


def read(path: Path = PIDFILE) -> Owner | None:
    """Parse the pidfile, or None if missing/empty/malformed."""
    try:
        text = path.read_text()
    except OSError:
        return None
    lines = text.splitlines()
    if not lines:
        return None
    try:
        pid = int(lines[0].strip())
    except ValueError:
        return None
    name = lines[1].strip() if len(lines) > 1 else ""
    exec_path = lines[2].strip() if len(lines) > 2 else ""
    return Owner(pid, name, exec_path or None)


def current_holder(path: Path = PIDFILE) -> Owner | None:
    """The *live* owner of the pidfile, or None (no file, a dead pid, or a pid
    that has since been recycled to an unrelated process)."""
    owner = read(path)
    if owner is None or not owner_is_live(owner, identity(owner.pid)):
        return None
    return owner


def acquire(
    name: str,
    pid: int | None = None,
    path: Path = PIDFILE,
    exec_path: str | None = None,
) -> Owner | None:
    """Claim the pidfile for *name*.

    Returns None on success, or the live foreign holder that blocked the claim
    (the caller then refuses to arm). A file held by a live *other* process
    blocks; our own pid, a dead pid, or a recycled one is overwritten. Written
    atomically (temp + rename).
    """
    me = os.getpid() if pid is None else pid
    mine = current_exec_path() if exec_path is None else exec_path
    holder = current_holder(path)
    if holder is not None and holder.pid != me:
        return holder
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f"{path.name}.{me}.tmp"
    tmp.write_text(f"{me}\n{name}\n{mine}\n")
    os.replace(tmp, path)
    return None


def release(name: str | None = None, pid: int | None = None, path: Path = PIDFILE) -> None:
    """Remove the pidfile if this pid still owns it (no-op otherwise)."""
    me = os.getpid() if pid is None else pid
    owner = read(path)
    if owner is not None and owner.pid == me:
        try:
            path.unlink()
        except OSError:
            pass
