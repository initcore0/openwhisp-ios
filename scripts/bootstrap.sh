#!/usr/bin/env bash
# Bootstrap the iOS project: ensure XcodeGen is available, then generate the
# .xcodeproj from project.yml (the source of truth; the project is git-ignored).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- Ensure xcodegen is installed ---------------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found on PATH."
  if command -v brew >/dev/null 2>&1; then
    echo "Installing via Homebrew..."
    brew install xcodegen
  else
    echo "error: Homebrew is not installed. Install XcodeGen manually:" >&2
    echo "  https://github.com/yonaskolb/XcodeGen" >&2
    exit 1
  fi
fi

echo "Using $(xcodegen --version)"

# --- Generate the project -----------------------------------------------------
xcodegen generate
echo "Generated OpenWhisp.xcodeproj from project.yml"
