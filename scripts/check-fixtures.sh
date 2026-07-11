#!/usr/bin/env bash
# Fixture integrity gate — runs in CI (no simulator, no `say`, deterministic).
#
# Validates the CHECKED-IN fixtures without regenerating them (so it works on a
# Linux/CI box that has no macOS `say`/`afconvert`): every `*.wav` in
# fixtures/audio/ must
#   - be a RIFF/WAVE file,
#   - be 16 kHz, mono, 16-bit PCM (the pipeline's native format),
#   - have a matching `*.txt` reference sidecar (may be empty, e.g. silence),
# and the expected multilingual + English fixtures must all be present.
#
# This is the Tier-1 fixtures gate: it fails CI if a fixture is corrupt, in the
# wrong format, or missing its reference — the cheapest guard against a bad
# `gen-fixtures.sh` run landing broken audio. Real-engine replay of these WAVs
# lives in the package tests (env-gated, WP3) and the nightly engine script.
#
# Usage: ./scripts/check-fixtures.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/fixtures/audio"

# Fixtures that MUST always be present (the English pipeline set). Multilingual
# fixtures are validated if present but not required to be — a machine without a
# given `say` voice legitimately can't regenerate one (documented in the README).
REQUIRED=(plain_speech numbers_dates speech_then_silence two_utterances silence)
EXPECTED_MULTILINGUAL=(spanish_greeting german_greeting french_greeting russian_greeting)

fail=0
err() { echo "  ✗ $*"; fail=1; }
ok()  { echo "  ✓ $*"; }

echo "Validating fixtures in $DIR"

[[ -d "$DIR" ]] || { echo "error: $DIR does not exist"; exit 1; }

# Parse a WAV header with pure python3 (present everywhere; no macOS tools).
wav_format() {
    python3 - "$1" <<'PY'
import sys, wave
try:
    w = wave.open(sys.argv[1], "rb")
except Exception as e:
    print(f"ERR {e}"); sys.exit(0)
print(f"{w.getframerate()} {w.getnchannels()} {w.getsampwidth()*8} {w.getnframes()}")
PY
}

for wav in "$DIR"/*.wav; do
    [[ -e "$wav" ]] || { err "no .wav files found"; break; }
    name="$(basename "$wav" .wav)"
    fmt="$(wav_format "$wav")"
    if [[ "$fmt" == ERR* ]]; then
        err "$name.wav is not a readable WAV ($fmt)"; continue
    fi
    read -r rate ch bits frames <<<"$fmt"
    if [[ "$rate" != "16000" || "$ch" != "1" || "$bits" != "16" ]]; then
        err "$name.wav wrong format: ${rate}Hz ${ch}ch ${bits}bit (want 16000/1/16)"
    elif [[ "$frames" -le 0 ]]; then
        err "$name.wav has no audio frames"
    else
        ok "$name.wav — 16000/1/16, $frames frames"
    fi
    # Reference sidecar must exist (silence.txt is legitimately empty).
    [[ -f "$DIR/$name.txt" ]] || err "$name.wav has no .txt reference sidecar"
done

echo "Checking required English pipeline fixtures..."
for name in "${REQUIRED[@]}"; do
    [[ -f "$DIR/$name.wav" ]] && ok "$name present" || err "$name MISSING (required)"
done

echo "Checking multilingual fixtures (goal #1)..."
present=0
for name in "${EXPECTED_MULTILINGUAL[@]}"; do
    if [[ -f "$DIR/$name.wav" ]]; then ok "$name present"; present=$((present+1)); else echo "  – $name absent (voice not installed when generated?)"; fi
done
if [[ "$present" -eq 0 ]]; then
    err "no multilingual fixtures present — goal #1 coverage is missing; run scripts/gen-fixtures.sh on a Mac with es/de/fr/ru voices"
fi

if [[ "$fail" -ne 0 ]]; then
    echo "FIXTURE CHECK FAILED"; exit 1
fi
echo "All fixtures valid."
