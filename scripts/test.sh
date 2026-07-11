#!/usr/bin/env bash
# Run the always-green gate: `swift test` on the shared package. Fast (~seconds),
# no simulator, deterministic — the same law as the macOS repo's working agreement.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/Packages/OpenWhispMobileKit"

swift test "$@"
