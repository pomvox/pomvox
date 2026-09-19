#!/usr/bin/env bash
# The app bundles a verbatim copy of the cleanup SDK's pack manifest. Its exact
# bytes are the manifest digest the SDK records as provenance, so the copy must
# never be re-serialized or edited — only replaced wholesale when the submodule
# moves. The unit test pins the same bytes by hash (it cannot read the submodule:
# the working copy is on iCloud Drive, where an evicted file blocks forever).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bundled="$root/Pomvox/Resources/simplewords-v3.pack.json"
vendored="$root/vendor/pomvox-cleanup-engine/packs/simplewords-v3/pack.json"

if [ ! -f "$vendored" ]; then
  echo "check-cleanup-pack-manifest: submodule not checked out (git submodule update --init) — skipping"
  exit 0
fi
if ! cmp -s "$bundled" "$vendored"; then
  echo "check-cleanup-pack-manifest: FAIL — $bundled differs from the SDK's manifest" >&2
  echo "  copy it verbatim:  cp '$vendored' '$bundled'" >&2
  echo "  and update the hash pinned in CleanupPackInstallerTests." >&2
  exit 1
fi
echo "check-cleanup-pack-manifest: ok  $(shasum -a 256 "$bundled" | cut -d' ' -f1)"
