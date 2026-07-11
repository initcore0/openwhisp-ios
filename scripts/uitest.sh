#!/usr/bin/env bash
# Run the simulator XCUITest suites on a booted iOS simulator.
#
# Boots (or reuses) an iOS simulator, then runs the UI-test schemes:
#   - OpenWhispUITests    — launches the REAL host app, asserts the home renders.
#   - UITestHostUITests   — types "Hello, world!" into a text field with the
#                           SYSTEM keyboard (our keyboard extension is NOT
#                           enabled here — that path is a manual/real-device
#                           checklist; see docs/TESTING.md).
#
# Deterministic and CI-safe: unsigned simulator run, fixed device, xcresult and
# a screenshot dropped under .build/ for inspection.
#
# Usage:
#   ./scripts/uitest.sh                  # both suites, default device
#   ./scripts/uitest.sh OpenWhispUITests # one scheme
#   OPENWHISP_SIM_DEVICE="iPhone 17" OPENWHISP_SIM_OS="26.5" ./scripts/uitest.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null 2>&1 || { echo "installing xcodegen…"; brew install xcodegen; }
"$ROOT/scripts/bootstrap.sh" >/dev/null

DEVICE="${OPENWHISP_SIM_DEVICE:-iPhone 17}"
OS="${OPENWHISP_SIM_OS:-26.5}"
PROJECT="OpenWhisp.xcodeproj"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"
RESULTS_DIR="$ROOT/.build/uitest-results"
mkdir -p "$RESULTS_DIR"

# Schemes to run (default: both). Any args override.
if [[ "$#" -gt 0 ]]; then
  SCHEMES=("$@")
else
  SCHEMES=(OpenWhispUITests UITestHostUITests)
fi

# --- Boot (or reuse) the target simulator ------------------------------------
echo "==> Resolving simulator: $DEVICE (iOS $OS)"
# Match "    <DEVICE> (<UDID>) (<state>)" by literal name (trailing " (" anchors
# it so "iPhone 17" won't match "iPhone 17 Pro"), then extract the UUID.
DEVICE_LINE="$(xcrun simctl list devices available | grep -F "    $DEVICE (" | head -1)"
UDID="$(printf '%s' "$DEVICE_LINE" | grep -oE '[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}' | head -1)"
if [[ -z "${UDID:-}" ]]; then
  echo "error: no available simulator named '$DEVICE' (iOS $OS). Available:" >&2
  xcrun simctl list devices available | grep -i iphone >&2
  exit 1
fi
echo "    UDID: $UDID"

STATE="$(xcrun simctl list devices | grep "$UDID" | grep -oE '\((Booted|Shutdown)\)' | tr -d '()' || true)"
if [[ "$STATE" != "Booted" ]]; then
  echo "==> Booting $DEVICE…"
  xcrun simctl boot "$UDID"
fi
# Wait until the device is fully booted (springboard up).
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

DEST="platform=iOS Simulator,id=$UDID"

fail=0
for scheme in "${SCHEMES[@]}"; do
  echo ""
  echo "==> Running UI test scheme: $scheme"
  result="$RESULTS_DIR/$scheme.xcresult"
  rm -rf "$result"
  set +e
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "$DEST" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$result" \
    CODE_SIGNING_ALLOWED=NO \
    | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat)
  rc=${PIPESTATUS[0]}
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "    ✗ $scheme FAILED (rc=$rc); xcresult at $result"
    fail=1
  else
    echo "    ✓ $scheme passed; xcresult at $result"
  fi
done

exit "$fail"
