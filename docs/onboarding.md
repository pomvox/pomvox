# Day one: setting up to work on Pomvox

For a new contributor on a fresh Mac. Follow it top to bottom; it should take
about an hour, most of which is downloads.

## What you need before you start

- **An Apple Silicon Mac** (M1 or later), macOS 14 or newer. Not optional — the
  speech model runs on the Neural Engine and the cleanup model on the GPU.
  Nothing about the app runs on Intel or in a VM.
- **~20 GB free disk.** Xcode is ~15 GB, the models are ~2.6 GB, and build
  folders are a few GB more.
- A GitHub account.

You do **not** need an Apple Developer account to contribute. That is only for
publishing releases — see [releasing.md](releasing.md).

## 1. Install the tools

Xcode first, because it is the long download:

1. Open the App Store, install **Xcode**, then launch it once and accept the
   licence. (Xcode 26.3 is what CI pins; newer may work, but if a build fails
   strangely, check this first.)
2. Then in Terminal:

```sh
xcode-select --install                      # command line tools
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install xcodegen gh
curl -LsSf https://astral.sh/uv/install.sh | sh     # Python package manager
gh auth login                                        # sign in to GitHub
```

**One setting that will waste your afternoon if you skip it.** Xcode's command
line tools and Xcode itself are different things, and the build needs the real
Xcode. Put this in your `~/.zshrc`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Then open a new terminal tab so it takes effect.

## 2. Get the code

```sh
mkdir -p ~/dev && cd ~/dev
git clone https://github.com/pomvox/pomvox.git
cd pomvox
```

**Clone into `~/dev`, not Desktop or Documents.** If iCloud Drive syncs your
Desktop, builds there fail in ways that look like compiler bugs: `git` commands
hang forever, code signing rejects the extra attributes iCloud adds, and Swift
package resolution stalls with no error. Every strange build problem in this
project's history traces back to this.

## 3. Make the signing certificate

macOS ties microphone and keyboard permissions to the app's *identity*. Without
a stable identity, every rebuild wipes your permissions and you re-grant them
all day. This creates a free, local, self-signed one:

```sh
scripts/dev-signing-cert.sh
```

It asks for a GUI password prompt to trust the certificate. Say yes. Once only.

## 4. Build and run it

```sh
cd Pomvox && xcodegen generate && cd ..
xcodebuild -project Pomvox/Pomvox.xcodeproj -scheme Pomvox \
  -configuration Debug -derivedDataPath /tmp/pomvox-dd build

cp -R /tmp/pomvox-dd/Build/Products/Debug/Pomvox.app ~/Applications/
open ~/Applications/Pomvox.app
```

Note `-derivedDataPath /tmp/...` — build output goes outside the repo, always.

The app appears in your menu bar and opens a Setup window. Grant **Microphone**
and **Input Monitoring** when asked, then quit and reopen it once (macOS only
applies the keyboard grant on relaunch). Hold **Fn** and talk; let go and your
words paste into whatever app you were in.

First run downloads ~2.6 GB of models. Be patient once.

### If permissions refuse to stick

This is the single most common setup problem. In order:

1. Make sure only **one** copy of Pomvox exists. Two copies with the same
   identity — say one in `~/Applications` and one in Xcode's DerivedData —
   means you grant permission to one and run the other. Delete the spares.
2. Clear the stale permission records and try again:
   ```sh
   tccutil reset ListenEvent app.pomvox.hub
   tccutil reset Microphone app.pomvox.hub
   ```
3. Quit and reopen the app. Grant when prompted, rather than hunting for it in
   System Settings — the prompt is more reliable than the toggle.

## 5. Run the tests

```sh
uv sync && uv run pytest                     # Python spec suite, fast
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pomvox/Pomvox.xcodeproj -scheme Pomvox \
  -derivedDataPath /tmp/pomvox-dd -destination 'platform=macOS'
```

The Swift suite is ~635 tests and takes a few minutes. Some are skipped unless
you set an environment variable — those load the real 2 GB model and are not
part of normal work.

## 6. Make your first change

```sh
git checkout -b fix/some-small-thing
# ... edit ...
cd Pomvox && xcodegen generate && cd ..     # ONLY if you added or renamed a file
# ... build, test, try it in the app ...
git commit -am "fix: describe what changed"
gh pr create
```

**If you add a new file, you must run `xcodegen generate`.** The Xcode project
is generated from `Pomvox/project.yml` and is not in git. Forget this and your
new file silently is not compiled — and if it was a test file, the test run
reports success having run none of your tests.

## How the project is organised

Two codebases that share a config file and a database:

- `Pomvox/` — the Swift menu-bar app. This is what people actually run.
- `src/pomvox/` — a Python reference engine. Its pure-logic modules (state
  machines, guards, config) are the *specification*; the Swift side is checked
  against the same test vectors. Changing behaviour usually means changing both.
- `~/.pomvox/` — the user's config (`config.toml`), history database, and
  dictionary. Not in the repo.

Read `ARCHITECTURE.md` for how a dictation flows end to end, and
`CONTRIBUTING.md` for the four rules that decide whether a PR gets merged. The
one that surprises people: **never lose the user's words.** Every stage falls
back to the previous stage's output on any failure.

## Prompts to give Cursor or Claude Code

Paste these as your opening message. They work better than "help me with this
codebase" because they point at the real constraints.

**Getting oriented:**

> I'm new to this repo, a macOS dictation app called Pomvox. Read
> `ARCHITECTURE.md`, `CONTRIBUTING.md` and `docs/onboarding.md` first, then walk
> me through what happens from the moment I hold the Fn key to the moment text
> pastes — naming the actual files and functions involved. Don't write any code
> yet.

**Picking up a task:**

> Read `ARCHITECTURE.md` and `CONTRIBUTING.md`, then implement <the change>.
> Constraints that matter here: the Swift app in `Pomvox/` and the Python engine
> in `src/pomvox/` share pure-logic modules that are tested against the same
> vectors, so if you change behaviour in one, check whether the other needs the
> same change. Never remove a fallback path — a failure must paste the previous
> stage's text, never nothing. Add tests. Build with
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and
> `-derivedDataPath /tmp/pomvox-dd`, and run `cd Pomvox && xcodegen generate`
> if you add a file.

**When something behaves oddly on your machine:**

> Pomvox is behaving like this: <describe>. Before changing code, read the log
> with `log show --predicate 'process == "Pomvox"' --last 10m --style compact`
> and check `~/.pomvox/history.db` (table `history`, columns `raw_text`,
> `final_text`, `cleanup_status`, `timings_json`). Tell me what the evidence
> says before proposing a fix.

**Before opening a PR:**

> Review my diff against `CONTRIBUTING.md`'s ground rules. Check specifically:
> is there a fallback on every new failure path, is anything model-shaped
> hard-coded instead of read from config, and does any latency claim have a real
> measurement behind it? Then run the Swift and Python suites.

A note on trusting the answer: this codebase has a documented habit of
plausible optimisations that measurement refuted. If a model tells you something
is faster, ask it for the numbers from a real run on your Mac.

## The five things that will trip you up

1. Building anywhere under iCloud Drive (Desktop, Documents). Use `~/dev`.
2. Forgetting `xcodegen generate` after adding a file — your code is not built.
3. `DEVELOPER_DIR` not set, so `xcodebuild` uses the command line tools and
   refuses to run tests.
4. Two copies of the app installed, so permissions never stick.
5. Building into the repo instead of `/tmp` — slow, and it pollutes git status.
