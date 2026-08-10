#!/usr/bin/env bash
#
# publish-release.sh — publish a Pomvox release WITH the Sparkle appcast, in
# the only safe order: no client may ever see an appcast entry whose
# enclosure 404s, so the GitHub release (with assets) goes out FIRST and the
# appcast commit to main goes out LAST.
#
#   1. Preconditions: clean main, dist artifacts present, versions coherent.
#   2. EdDSA-sign dist/Pomvox.zip (sign_update, key from login Keychain).
#   3. Splice + validate the appcast item (scripts/make_appcast.py).
#   4. gh release create vX.Y.Z with Pomvox.dmg + Pomvox.zip.
#   5. Poll the enclosure URL until it serves HTTP 200.
#   6. EdDSA-verify the zip against SUPublicEDKey (belt over braces).
#   7. Commit + push appcast.xml.
#   8. Print the Homebrew cask bump reminder.
#
# Usage:   scripts/publish-release.sh v0.1.11
#          scripts/publish-release.sh v0.1.11 --dry-run     # steps 1-3 + 6 only,
#                                                           # signs with SIGN_KEY_FILE
# Env:     SIGN_KEY_FILE  file-based EdDSA key for --dry-run (never for real
#                         releases — the real key lives in the Keychain)
#
# After this script: bump the Homebrew cask (pomvox/homebrew-pomvox) —
#   version, sha256 (shasum -a 256 dist/Pomvox.dmg), plus ONCE:
#   `auto_updates true` and
#   `livecheck do; url "https://raw.githubusercontent.com/pomvox/pomvox/main/appcast.xml"; strategy :sparkle; end`
#
# Release checklist reminders (from the design spec):
#   - MARKETING_VERSION and CURRENT_PROJECT_VERSION bumped in Pomvox/project.yml
#     BEFORE notarize-release.sh (sparkle:version = CURRENT_PROJECT_VERSION).
#   - Never rotate the Developer ID cert and the EdDSA key in the same release.
set -euo pipefail

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
# die() exits via `exit 1` (EXIT, not ERR), so ERR traps never see it — the
# APPCAST_ROLLBACK sentinel makes die() itself undo an uncommitted splice
# (R3: e.g. the enclosure poll timing out AFTER the appcast was rewritten).
APPCAST_ROLLBACK=0
die() {
  [ "${APPCAST_ROLLBACK:-0}" = "1" ] && git checkout -- "$APPCAST" 2>/dev/null || true
  printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1
}

TAG="${1:-}"; [ -n "$TAG" ] || { echo "usage: $0 vX.Y.Z [--dry-run]" >&2; exit 2; }
# Finding 6: a malformed tag propagates into the appcast's enclosure URL and
# release-notes link — cheap to reject up front.
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must look like vX.Y.Z"
DRY_RUN="${2:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
ZIP="dist/Pomvox.zip"; DMG="dist/Pomvox.dmg"; APPCAST="appcast.xml"
SHORT="${TAG#v}"

if [ -n "$DRY_RUN" ] && [ "$DRY_RUN" != "--dry-run" ]; then
  die "unknown argument: $DRY_RUN (expected --dry-run)"
fi

say "Preconditions"
if [ "$DRY_RUN" != "--dry-run" ]; then
  [ "$(git branch --show-current)" = "main" ] || die "not on main"
fi
git diff --quiet && git diff --cached --quiet || die "working tree not clean"
[ -f "$ZIP" ] && [ -f "$DMG" ] || die "dist artifacts missing — run scripts/notarize-release.sh first"
grep -q "MARKETING_VERSION: \"$SHORT\"" Pomvox/project.yml \
  || die "project.yml MARKETING_VERSION does not match $TAG"
BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' Pomvox/project.yml)"
[ -n "$BUILD" ] || die "could not read CURRENT_PROJECT_VERSION"
PUBKEY="$(sed -n 's/.*SUPublicEDKey: \(.*\)/\1/p' Pomvox/project.yml | tr -d ' "')"
[ -n "$PUBKEY" ] || die "could not read SUPublicEDKey from project.yml"

# Finding 3: Sparkle does NOT verify appcast-version-vs-bundle-version — it
# only decorates errors — so a stale dist/Pomvox.zip (e.g. forgot to re-run
# notarize-release.sh after bumping project.yml) would ship a fleet-wide
# update loop: every client re-downloads the "new" version forever. Real
# path only — the --dry-run fixture zip isn't a real app bundle.
if [ "$DRY_RUN" != "--dry-run" ]; then
  ZVER="$(unzip -p "$ZIP" 'Pomvox.app/Contents/Info.plist' | plutil -extract CFBundleShortVersionString raw -o - -- - 2>/dev/null || true)"
  ZBUILD="$(unzip -p "$ZIP" 'Pomvox.app/Contents/Info.plist' | plutil -extract CFBundleVersion raw -o - -- - 2>/dev/null || true)"
  [ "$ZVER" = "$SHORT" ] && [ "$ZBUILD" = "$BUILD" ] \
    || die "dist/Pomvox.zip is $ZVER ($ZBUILD), expected $SHORT ($BUILD) — stale dist? re-run notarize-release.sh"
fi
echo "  ✓ $TAG (marketing $SHORT, build $BUILD)"

say "EdDSA-signing $ZIP"
if [ "$DRY_RUN" = "--dry-run" ] && [ -z "${SIGN_KEY_FILE:-}" ]; then
  die "SIGN_KEY_FILE is required for --dry-run (never the Keychain key)"
fi
BIN="$(scripts/sparkle-tools.sh)"
if [ "$DRY_RUN" = "--dry-run" ]; then
  SIGN_OUT="$("$BIN/sign_update" --ed-key-file "$SIGN_KEY_FILE" "$ZIP")"
else
  SIGN_OUT="$("$BIN/sign_update" "$ZIP")"   # key from login Keychain
fi
SIG="$(printf '%s' "$SIGN_OUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
[ -n "$SIG" ] || die "sign_update produced no signature: $SIGN_OUT"
echo "  ✓ signature: ${SIG:0:16}…"

if [ "$DRY_RUN" != "--dry-run" ]; then
  # Finding 5: from here through the appcast commit, anything that dies
  # (network blip, gh failure, etc.) must not leave a modified-but-uncommitted
  # appcast.xml sitting in the working tree — roll it back and re-raise.
  # ERR covers unchecked failures; APPCAST_ROLLBACK covers die() paths (R3).
  trap 'git checkout -- "$APPCAST" 2>/dev/null || true' ERR
  APPCAST_ROLLBACK=1
fi

say "Building + validating the appcast item"
uv run --frozen python3 scripts/make_appcast.py --appcast "$APPCAST" --zip "$ZIP" \
  --tag "$TAG" --short-version "$SHORT" --build "$BUILD" --signature "$SIG" --write
git diff --stat -- "$APPCAST"

if [ "$DRY_RUN" = "--dry-run" ]; then
  say "Dry run: verifying signature locally, then rolling back the appcast"
  # Finding 11: SIGN_KEY_FILE is required above, but if its .pub sidecar is
  # missing, silently falling back to the production SUPublicEDKey would
  # verify against the WRONG key and could mask a real signing bug — die
  # instead of guessing.
  [ -f "${SIGN_KEY_FILE}.pub" ] \
    || die "SIGN_KEY_FILE is set but ${SIGN_KEY_FILE}.pub is missing — can't verify the dry-run signature"
  PUBKEY="$(cat "${SIGN_KEY_FILE}.pub")"
  # Roll back the appcast on EVERY dry-run outcome — the verify must not be
  # able to leave the tree dirty under set -e.
  if ! uv run --frozen python3 - "$ZIP" "$SIG" "$PUBKEY" <<'PY'
import sys; sys.path.insert(0, "scripts")
from make_appcast import verify_signature
ok = verify_signature(sys.argv[1], sys.argv[2], sys.argv[3])
print("  ✓ EdDSA signature verifies" if ok else "  ✗ signature does NOT verify"); sys.exit(0 if ok else 1)
PY
  then
    git checkout -- "$APPCAST"
    die "dry-run signature verification failed (appcast rolled back)"
  fi
  git checkout -- "$APPCAST"
  say "Dry run complete (no release created, appcast unchanged)"
  exit 0
fi

say "Publishing the GitHub release FIRST (assets before appcast — no 404s)"
gh release create "$TAG" "$DMG" "$ZIP" --title "Pomvox $SHORT" --generate-notes

say "Waiting for the enclosure to serve HTTP 200"
URL="https://github.com/pomvox/pomvox/releases/download/$TAG/Pomvox.zip"
for i in $(seq 1 30); do
  # Finding 5: a transient curl failure (DNS blip, connection reset) must not
  # kill the whole script under set -e — treat it as "not ready yet" and retry.
  code="$(curl -sIL -o /dev/null -w '%{http_code}' "$URL" || echo 000)"
  [ "$code" = "200" ] && break
  echo "  … $code, retry $i/30"; sleep 10
done
[ "$code" = "200" ] || die "enclosure never resolved: $URL"
echo "  ✓ $URL"

say "EdDSA-verifying the zip against SUPublicEDKey"
uv run --frozen python3 - "$ZIP" "$SIG" "$PUBKEY" <<'PY'
import sys; sys.path.insert(0, "scripts")
from make_appcast import verify_signature
ok = verify_signature(sys.argv[1], sys.argv[2], sys.argv[3])
print("  ✓ signature verifies against the shipped public key" if ok else "  ✗ MISMATCH"); sys.exit(0 if ok else 1)
PY

say "Committing the appcast LAST"
git add "$APPCAST"
git commit -m "release: appcast entry for $TAG"
trap - ERR   # appcast is committed now — nothing left in the working tree to roll back
APPCAST_ROLLBACK=0
git push origin main

say "Done — now bump the Homebrew cask (see header)."
echo "  raw.githubusercontent.com caches ~5 min; clients see $TAG within the day."
