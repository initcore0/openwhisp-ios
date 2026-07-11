#!/usr/bin/env bash
# Unsigned simulator build of all three product targets. Uses a generic iOS
# Simulator destination so it needs only the SDK (no booted simulator, no
# downloaded runtime) and no signing identity/team.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Ensure the project exists / is current.
"$ROOT/scripts/bootstrap.sh"

DEST='generic/platform=iOS Simulator'
PROJECT="OpenWhisp.xcodeproj"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/.build/DerivedData}"

# One scheme per product target (declared in project.yml). Building the OpenWhisp
# app scheme also embeds and validates the keyboard + widgets app-extensions; we
# additionally build each extension scheme so every target is proven to build in
# isolation.
for scheme in OpenWhisp OpenWhispKeyboard OpenWhispWidgets; do
  echo "==> Building $scheme (unsigned, simulator)"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "$DEST" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat)
done

echo "All three targets built for the simulator."
