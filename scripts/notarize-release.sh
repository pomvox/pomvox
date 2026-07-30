#!/usr/bin/env bash
#
# notarize-release.sh — build, sign, notarize, and staple a distributable Pomvox.app.
#
# This is the M7b distribution pipeline. It builds the Release configuration
# (Developer ID Application + hardened runtime + Pomvox.entitlements, see
# Pomvox/project.yml), notarizes + staples both the .app and a drag-to-Applications
# .dmg, so the download clears Gatekeeper offline. The result is dist/Pomvox.dmg
# (primary) plus dist/Pomvox.zip (the notarized .app).
#
# ── One-time setup ──────────────────────────────────────────────────────────
#   1. Create the signing cert (once): Xcode ▸ Settings ▸ Accounts ▸ your Apple
#      ID ▸ Manage Certificates ▸ "+" ▸ "Developer ID Application".
#
#   2. Create an app-specific password at appleid.apple.com ▸ Sign-In & Security
#      ▸ App-Specific Passwords, then store a notarytool keychain profile (once):
#
#        xcrun notarytool store-credentials "pomvox-notary" \
#          --apple-id "you@example.com" --team-id "CT84AT52RS" \
#          --password "abcd-efgh-ijkl-mnop"
#
#      (An App Store Connect API key works too — pass --key/--key-id/--issuer
#      to `notarytool submit` instead of --keychain-profile.)
#
# ── Usage ───────────────────────────────────────────────────────────────────
#   scripts/notarize-release.sh
#
# Override any of these via the environment:
#   TEAM_ID        Apple Developer team id            (default: CT84AT52RS)
#   NOTARY_PROFILE notarytool keychain profile name   (default: pomvox-notary)
#   DEVELOPER_DIR  Xcode.app developer dir            (default: /Applications/Xcode.app/...)
#   DD             derived-data path (keep OFF iCloud) (default: /tmp/pomvox-release-dd)
#   OUT            output dir for the zip             (default: ./dist)
#
set -euo pipefail

TEAM_ID="${TEAM_ID:-CT84AT52RS}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pomvox-notary}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DD="${DD:-/tmp/pomvox-release-dd}"           # never build on the iCloud Desktop —
OUT="${OUT:-$(pwd)/dist}"                     # codesign rejects iCloud xattrs.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ_DIR="$REPO_ROOT/Pomvox"
APP="$DD/Build/Products/Release/Pomvox.app"
ZIP="$OUT/Pomvox.zip"
DMG="$OUT/Pomvox.dmg"

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── Preflight ───────────────────────────────────────────────────────────────
say "Preflight"
[ -d "$DEVELOPER_DIR" ] || die "DEVELOPER_DIR not found: $DEVELOPER_DIR (install Xcode, not just CLT)."

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  die "No 'Developer ID Application' certificate in the keychain.
     Create it in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application."
fi
echo "  ✓ Developer ID Application cert present"
echo "  ✓ team $TEAM_ID, notary profile '$NOTARY_PROFILE'"

command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)."

# ── Build (Release: Developer ID + hardened runtime + entitlements) ──────────
say "Generating project"
( cd "$PROJ_DIR" && xcodegen generate >/dev/null )

say "Building Release"
# ARCHS=arm64: Pomvox is Apple-Silicon-only — a universal build dies in
# CreateUniversalBinary on mlx's Cmlx target (no x86_64 slice).
xcodebuild \
  -project "$PROJ_DIR/Pomvox.xcodeproj" \
  -scheme Pomvox \
  -configuration Release \
  -derivedDataPath "$DD" \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 \
  clean build | tail -5

[ -d "$APP" ] || die "Build did not produce $APP"

# ── Re-sign embedded Sparkle (M8) ────────────────────────────────────────────
# Xcode copies Sparkle's prebuilt nested executables (Autoupdate, Updater.app,
# the two XPC services) with Sparkle's own signatures — no Developer ID, no
# secure timestamp — and Apple's notary rejects every one of them. Re-sign
# inside-out with our identity (preserving Sparkle's entitlements, which the
# sandboxed Downloader.xpc needs), then reseal the framework and the app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
  say "Re-signing embedded Sparkle (Developer ID + runtime + timestamp)"
  resign() { codesign --force --sign "Developer ID Application" --options runtime \
               --timestamp --preserve-metadata=entitlements "$1"; }
  resign "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
  resign "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
  resign "$SPARKLE_FW/Versions/B/Updater.app"
  resign "$SPARKLE_FW/Versions/B/Autoupdate"
  resign "$SPARKLE_FW"
  codesign --force --sign "Developer ID Application" --options runtime --timestamp \
    --entitlements "$PROJ_DIR/Pomvox.entitlements" "$APP"
fi

# ── Verify the signature before we waste a notary round-trip ─────────────────
say "Verifying signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime" \
  || die "App is not Developer-ID-signed with the hardened runtime — check project.yml Release config."
echo "  ✓ signed + hardened"

# ── Notarize ─────────────────────────────────────────────────────────────────
mkdir -p "$OUT"
say "Zipping for notarization"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

say "Submitting to Apple notary (this can take a few minutes)"
# notarytool --wait can exit 0 with status "Invalid" — gate on Accepted, not $?.
NOTARY_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee /dev/stderr)" || true
echo "$NOTARY_OUT" | grep -q "status: Accepted" \
  || die "Notarization was not Accepted. Inspect the log:
     xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"

# ── Staple + repackage the stapled app ───────────────────────────────────────
say "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

say "Repackaging stapled app"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

# Gatekeeper assessment of the app itself — what a downloader's Mac decides.
say "Gatekeeper assessment (app)"
spctl --assess --type execute --verbose=2 "$APP" || true

# ── Build the distributable DMG (drag-to-Applications) ───────────────────────
# The .app is already notarized + stapled above, so it works even dragged out of
# the DMG. We then notarize + staple the DMG itself so the download clears
# Gatekeeper directly.
say "Building DMG"
STAGE="$(mktemp -d)/Pomvox"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance
rm -f "$DMG"
hdiutil create -volname "Pomvox" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | tail -1
rm -rf "$(dirname "$STAGE")"

say "Signing the DMG (Developer ID)"
codesign --force --timestamp --sign "Developer ID Application" "$DMG"

say "Notarizing the DMG (another few minutes)"
NOTARY_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee /dev/stderr)" || true
echo "$NOTARY_OUT" | grep -q "status: Accepted" \
  || die "DMG notarization was not Accepted. Inspect the log:
     xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE"

say "Stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

say "Gatekeeper assessment (DMG)"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true

say "Done"
echo "  Distribute → $DMG   (notarized + stapled, drag-to-Applications)"
echo "  Also available → $ZIP   (notarized + stapled .app)"
echo "  Publish: shasum -a 256 \"$DMG\""
echo "  Next: scripts/publish-release.sh vX.Y.Z   (GitHub release + Sparkle appcast)"
