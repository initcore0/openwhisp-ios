#!/usr/bin/env bash
# One-command "see the app": boot (or reuse) an iOS simulator, build + install
# the host app unsigned, launch it, and open the Simulator UI so a human can
# poke at it. Also drops a screenshot under .build/ as proof it launched.
#
# Usage:
#   ./scripts/run-sim.sh
#   OPENWHISP_SIM_DEVICE="iPhone 17 Pro" OPENWHISP_SIM_OS="26.5" ./scripts/run-sim.sh
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
APP_BUNDLE_ID="app.openwhisp.ios"
SHOT="$ROOT/.build/run-sim-launch.png"

# --- Resolve + boot the simulator --------------------------------------------
echo "==> Resolving simulator: $DEVICE (iOS $OS)"
UDID="$(resolve_sim_udid "$DEVICE" "$OS")"
[[ -n "$UDID" ]] || die_no_sim "$DEVICE" "$OS"
echo "    UDID: $UDID"
boot_sim "$UDID"
# Bring the Simulator.app window up so the human can watch (best-effort).
open -a Simulator >/dev/null 2>&1 || true

# --- Build the host app (unsigned) -------------------------------------------
echo "==> Building OpenWhisp (unsigned, simulator)..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme OpenWhisp \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat)

# Pin to the Debug product: the build above is Debug (fixtures bundled), but a
# stale Release product from another task may coexist in DerivedData and a
# blind find could install the fixture-less Release app.
APP_PATH="$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name 'OpenWhisp.app' -type d 2>/dev/null | head -1)"
[[ -n "$APP_PATH" ]] || { echo "error: could not locate built OpenWhisp.app under $DERIVED"; exit 1; }
echo "    Built: $APP_PATH"

# --- Install + launch ---------------------------------------------------------
echo "==> Installing + launching..."
xcrun simctl install "$UDID" "$APP_BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"
# Terminate any stale instance so the launch below actually re-renders the UI.
xcrun simctl terminate "$UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$APP_BUNDLE_ID"

# Wait for the app process to actually be up, then let its first frame render,
# so the proof screenshot shows the app UI and not the springboard mid-launch.
for _ in $(seq 1 20); do
  if xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -qi "$APP_BUNDLE_ID"; then
    break
  fi
  sleep 0.5
done
sleep 2
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1 || true
echo "==> Launched. Screenshot: $SHOT"
echo "    (The Simulator window is open; interact with the app there.)"
