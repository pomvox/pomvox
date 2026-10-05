#!/usr/bin/env bash
# The app bundles a verbatim copy of the cleanup engine's pack manifest. Its
# exact bytes are the manifest digest the engine records as provenance, so the
# copy must never be re-serialized or edited — only replaced wholesale when the
# engine pin moves. The unit test pins the same bytes by hash
# (SDKPackProvisioner.bundledManifestSHA256).
#
# The engine reaches the app as SwiftPM packages pinned in Pomvox/project.yml:
# PomvoxCleanupMLX (pomvox-cleanup-mlx) at an exact version, which in turn pins
# pomvox-cleanup-engine exactly. This script reads the mlx pin from project.yml,
# reads the engine pin from pomvox-cleanup-mlx's Package.swift at that tag, then
# fetches the engine's packs/simplewords-v3/pack.json at the engine's tag and
# requires it to be byte-identical to the bundled copy, with the same SHA-256 as
# the constant in SDKPackProvisioner.swift.
#
# Needs only bash, curl and sha256sum/shasum — no Xcode. Every missing input is
# a failure, never a skip.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
project="$root/Pomvox/project.yml"
bundled="$root/Pomvox/Resources/simplewords-v3.pack.json"
provisioner="$root/Pomvox/Sources/Engine/SDKPackProvisioner.swift"
pack_path="packs/simplewords-v3/pack.json"
me="check-cleanup-pack-manifest"

fail() {
  echo "$me: FAIL — $*" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "neither sha256sum nor shasum is installed"
  fi
}

# Fetch a raw file at a tag; SwiftPM resolves exact "X" to tag "X" or "vX".
fetch_at_tag() {
  local repo="$1" version="$2" path="$3" out="$4" tag
  for tag in "v$version" "$version"; do
    if curl -fsSL --retry 3 -o "$out" \
      "https://raw.githubusercontent.com/pomvox/$repo/$tag/$path"; then
      echo "$tag"
      return 0
    fi
  done
  return 1
}

command -v curl >/dev/null 2>&1 || fail "curl is not installed"
[ -f "$project" ] || fail "$project not found"
[ -f "$bundled" ] || fail "bundled manifest $bundled not found"
[ -f "$provisioner" ] || fail "$provisioner not found"

# The exactVersion on the line after the pomvox-cleanup-mlx url.
mlx_version="$(awk '
  /url:[[:space:]]*https:\/\/github\.com\/pomvox\/pomvox-cleanup-mlx(\.git)?[[:space:]]*$/ { hit = 1; next }
  hit && /exactVersion:/ { gsub(/.*exactVersion:[[:space:]]*|["'\''[:space:]]/, ""); print; exit }
  hit && /url:/ { exit }
' "$project")"
[ -n "$mlx_version" ] ||
  fail "no exactVersion for pomvox-cleanup-mlx in $project (the engine must be pinned exact)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mlx_tag="$(fetch_at_tag pomvox-cleanup-mlx "$mlx_version" Package.swift "$tmp/Package.swift")" ||
  fail "could not fetch pomvox-cleanup-mlx Package.swift at v$mlx_version or $mlx_version"
engine_version="$(sed -n 's/.*pomvox-cleanup-engine\(\.git\)\{0,1\}"[^)]*exact:[[:space:]]*"\([^"]*\)".*/\2/p' \
  "$tmp/Package.swift" | head -n1)"
[ -n "$engine_version" ] ||
  fail "pomvox-cleanup-mlx $mlx_tag does not pin pomvox-cleanup-engine with exact: in Package.swift"

engine_tag="$(fetch_at_tag pomvox-cleanup-engine "$engine_version" "$pack_path" "$tmp/pack.json")" ||
  fail "could not fetch pomvox-cleanup-engine $pack_path at v$engine_version or $engine_version"

engine_sha="$(sha256 "$tmp/pack.json")"
bundled_sha="$(sha256 "$bundled")"
pinned_sha="$(sed -n 's/^[[:space:]]*"\([0-9a-f]\{64\}\)"[[:space:]]*$/\1/p' "$provisioner" | head -n1)"
[ -n "$pinned_sha" ] || fail "bundledManifestSHA256 not found in $provisioner"

echo "$me: project.yml pins pomvox-cleanup-mlx $mlx_version ($mlx_tag) -> pomvox-cleanup-engine $engine_version ($engine_tag)"
echo "  engine   $engine_sha  $pack_path@$engine_tag"
echo "  bundled  $bundled_sha  Pomvox/Resources/simplewords-v3.pack.json"
echo "  pinned   $pinned_sha  SDKPackProvisioner.bundledManifestSHA256"

if ! cmp -s "$tmp/pack.json" "$bundled" || [ "$engine_sha" != "$bundled_sha" ]; then
  echo "$me: FAIL — the bundled manifest differs from the engine's at $engine_tag" >&2
  echo "  copy it verbatim:  curl -fsSL https://raw.githubusercontent.com/pomvox/pomvox-cleanup-engine/$engine_tag/$pack_path -o Pomvox/Resources/simplewords-v3.pack.json" >&2
  echo "  and set SDKPackProvisioner.bundledManifestSHA256 to $engine_sha." >&2
  exit 1
fi
[ "$pinned_sha" = "$bundled_sha" ] ||
  fail "SDKPackProvisioner.bundledManifestSHA256 is $pinned_sha, the bundled manifest hashes to $bundled_sha"

echo "$me: ok  $bundled_sha"
