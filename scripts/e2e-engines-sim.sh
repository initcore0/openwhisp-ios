#!/usr/bin/env bash
# Env-gated REAL-engine tests on a simulator (Tier "env-gated real-engine runs").
#
# Runs the OpenWhispMobileKit package test suite on a booted iOS SIMULATOR with
# the real-engine gate open, so the env-gated engine tests (Parakeet via
# FluidAudio / WhisperKit, replaying fixtures/audio/*.wav through the real
# Streaming/FileTranscription engines) actually execute. Without the gate those
# tests skip themselves.
#
# HOW THE GATE REACHES THE TEST PROCESS: xcodebuild forwards environment
# variables prefixed TEST_RUNNER_ to the test runner (prefix stripped). A plain
# exported var or a trailing KEY=VALUE build-setting arg does NOT reach the
# tests — that exact dead-gate bug was caught in review; do not "simplify" this
# back.
#
# WHY a simulator destination (not plain `swift test`): the real engines link
# CoreML / the FluidAudio + WhisperKit runtimes, which need an iOS runtime.
#
# WHY cd into the package: the XcodeGen project's package-product schemes
# (CaptureKit etc.) are build-only. Running xcodebuild from the package
# directory synthesizes the test-configured "OpenWhispMobileKit-Package"
# scheme covering every test target, including CaptureKitTests.
#
# FIRST RUN DOWNLOADS MODELS (Parakeet variants / WhisperKit) — minutes + real
# bandwidth, cached thereafter. This tier is LOCAL/NIGHTLY, never the CI gate.
#
# Usage:
#   ./scripts/e2e-engines-sim.sh
#   OPENWHISP_SIM_DEVICE="iPhone 17" OPENWHISP_SIM_OS="26.5" ./scripts/e2e-engines-sim.sh
#   OPENWHISP_ENGINE_TEST_SCHEME=<scheme> ./scripts/e2e-engines-sim.sh   # override
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/sim-helpers.sh
source "$ROOT/scripts/sim-helpers.sh"

DEVICE="${OPENWHISP_SIM_DEVICE:-iPhone 17}"
OS="${OPENWHISP_SIM_OS:-26.5}"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/.build/DerivedData-e2e}"
PKG_DIR="$ROOT/Packages/OpenWhispMobileKit"
RESULT="$ROOT/.build/e2e-engines.xcresult"
ENGINE_TEST_SCHEME="${OPENWHISP_ENGINE_TEST_SCHEME:-OpenWhispMobileKit-Package}"

echo "Real-engine gate OPEN (TEST_RUNNER_OPENWHISP_E2E_ENGINES=1)."
echo "NOTE: first run downloads model weights from the network - this can take"
echo "      several minutes and is why this tier is local/nightly, not CI."

# --- Resolve + boot the simulator --------------------------------------------
echo "==> Resolving simulator: $DEVICE (iOS $OS)"
UDID="$(resolve_sim_udid "$DEVICE" "$OS")"
[[ -n "$UDID" ]] || die_no_sim "$DEVICE" "$OS"
echo "    UDID: $UDID"
boot_sim "$UDID"
DEST="platform=iOS Simulator,id=$UDID"

# --- Run the package tests on the simulator with the gate open ---------------
rm -rf "$RESULT"
echo "==> Running package tests on the simulator (scheme: $ENGINE_TEST_SCHEME)"
set +e
(
  cd "$PKG_DIR"
  TEST_RUNNER_OPENWHISP_E2E_ENGINES=1 xcodebuild test \
    -scheme "$ENGINE_TEST_SCHEME" \
    -destination "$DEST" \
    -derivedDataPath "$DERIVED" \
    -resultBundlePath "$RESULT" \
    CODE_SIGNING_ALLOWED=NO
) 2>&1 | (command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat)
rc=${PIPESTATUS[0]}
set -e

if [[ "$rc" -ne 0 ]]; then
  echo ""
  echo "e2e-engines-sim: scheme '$ENGINE_TEST_SCHEME' failed (rc=$rc)."
  echo "xcresult: $RESULT"
  echo "Override the scheme with OPENWHISP_ENGINE_TEST_SCHEME=<name> if it differs."
  exit "$rc"
fi
echo "e2e-engines-sim: done. xcresult: $RESULT"
