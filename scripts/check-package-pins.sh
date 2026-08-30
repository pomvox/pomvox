#!/usr/bin/env bash
# Assert that the load-bearing SwiftPM version pins survive project generation.
#
# Two packages are held below a specific version, and neither constraint is
# visible from the app's own sources — so if a pin is loosened, nothing fails
# until CI dies in a way that looks unrelated to the change. This is that loud
# failure. Run after `xcodegen generate`.
#
#   FluidAudio        < 0.15.6  — 0.15.6 added NemoTextProcessing.xcframework,
#                                 whose Headers/module.modulemap collides with
#                                 swift-tokenizers' TokenizersRust.xcframework
#                                 in the shared $(BUILT_PRODUCTS_DIR)/include/
#                                 ("Multiple commands produce …module.modulemap").
#   swift-tokenizers  < 0.6.0   — 0.6 made encode/decode throwing, which
#                                 swift-tokenizers-mlx 0.3.0 doesn't compile
#                                 against.
set -euo pipefail

PROJECT="${1:-Pomvox/Pomvox.xcodeproj/project.pbxproj}"

if [[ ! -f "$PROJECT" ]]; then
  echo "check-package-pins: no generated project at $PROJECT (run xcodegen generate first)" >&2
  exit 1
fi

fail=0

check_pin() {
  local url="$1" want_min="$2" want_max="$3" block
  block=$(grep -A6 -F "$url" "$PROJECT" || true)
  if [[ -z "$block" ]]; then
    echo "check-package-pins: MISSING package reference for $url" >&2
    fail=1
    return
  fi
  for want in "kind = versionRange" "minimumVersion = $want_min" "maximumVersion = $want_max"; do
    if ! grep -qF "$want" <<<"$block"; then
      echo "check-package-pins: $url lost its pin — expected '$want' in:" >&2
      echo "$block" >&2
      fail=1
      return
    fi
  done
  echo "check-package-pins: ok  $url  pinned [$want_min, $want_max)"
}

check_pin "FluidInference/FluidAudio.git"        "0.15.0" "0.15.6"
check_pin "DePasqualeOrg/swift-tokenizers.git"   "0.5.0"  "0.6.0"

exit "$fail"
