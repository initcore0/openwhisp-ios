#!/usr/bin/env bash
# Live drive of the REAL OpenWhisp keyboard extension on a simulator.
#
# Unlike scripts/uitest.sh (which uses the SYSTEM keyboard and is CI-safe), this
# enables OUR keyboard system-wide via `.GlobalPreferences AppleKeyboards`, then
# runs `OpenWhispKeyboardLiveUITests` which switches to it, types "Hey the 123 ok"
# across the 123/ABC page toggles, and (BLOCKER 2) stress-toggles 123→#+=→ABC to
# prove the rows stay stable. It also drops a fresh docs/assets/keyboard.png.
#
# Local/manual only — enabling a third-party keyboard in the simulator is exactly
# the kind of setup CI can't do deterministically (see docs/TESTING.md). Gated
# behind an env flag so it never runs in the always-green lane.
#
# Usage:
#   OPENWHISP_SIM_DEVICE="wp4fix" ./scripts/e2e-keyboard-live.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null 2>&1 || { echo "installing xcodegen..."; brew install xcodegen; }
"$ROOT/scripts/bootstrap.sh" >/dev/null
# shellcheck source=scripts/sim-helpers.sh
source "$ROOT/scripts/sim-helpers.sh"

DEVICE="${OPENWHISP_SIM_DEVICE:-iPhone 17}"
OS="${OPENWHISP_SIM_OS:-26.5}"
PROJECT="OpenWhisp.xcodeproj"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
KB_ID="app.openwhisp.ios.keyboard"
HOST_ID="app.openwhisp.ios"
SHOT="$ROOT/docs/assets/keyboard.png"

echo "==> Resolving simulator: $DEVICE (iOS $OS)"
UDID="$(resolve_sim_udid "$DEVICE" "$OS")"
[[ -n "$UDID" ]] || die_no_sim "$DEVICE" "$OS"
echo "    UDID: $UDID"
boot_sim "$UDID"
DEST="platform=iOS Simulator,id=$UDID"

echo "==> Building host app + keyboard extension (unsigned)"
xcodebuild build -project "$PROJECT" -scheme OpenWhisp -destination "$DEST" \
  -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO \
  | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat)

APP="$DERIVED/Build/Products/Debug-iphonesimulator/OpenWhisp.app"
echo "==> Installing host (embeds the keyboard appex)"
xcrun simctl install "$UDID" "$APP"
# Launch once so the container app has run (some extensions require it).
xcrun simctl launch "$UDID" "$HOST_ID" >/dev/null 2>&1 || true
sleep 1
xcrun simctl terminate "$UDID" "$HOST_ID" >/dev/null 2>&1 || true

echo "==> Enabling the OpenWhisp keyboard system-wide"
# Put ours FIRST so the globe cycle can't route around it, then reboot so the
# keyboard daemon reloads the list.
xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleKeyboards -array \
  "$KB_ID" "en_US@sw=QWERTY;hw=Automatic"
xcrun simctl spawn "$UDID" defaults write .GlobalPreferences AppleKeyboardsExpanded -int 1
xcrun simctl shutdown "$UDID"; sleep 2; xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b >/dev/null

echo "==> Driving the live keyboard suite"
RESULTS="$ROOT/.build/keyboard-live.xcresult"; rm -rf "$RESULTS"
TEST_RUNNER_OPENWHISP_LIVE_KEYBOARD=1 \
TEST_RUNNER_OPENWHISP_SHOT_PATH="$SHOT" \
xcodebuild test -project "$PROJECT" -scheme UITestHostUITests -destination "$DEST" \
  -derivedDataPath "$DERIVED" -resultBundlePath "$RESULTS" \
  -only-testing:UITestHostUITests/OpenWhispKeyboardLiveUITests \
  CODE_SIGNING_ALLOWED=NO \
  | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat)

echo "    ✓ live keyboard suite passed; screenshot at $SHOT; xcresult at $RESULTS"
