#!/usr/bin/env bash
# Generate the E2E audio-test fixture set in fixtures/audio/.
#
# Two families of fixture:
#
#   1. English pipeline fixtures (ported from the macOS repo's
#      scripts/gen-audio-fixtures.sh): plain speech, numbers/dates,
#      speech+silence tail, two-utterance pause split, and pure silence. These
#      drive the chunking / VAD / formatting / ordering pipeline.
#
#   2. Multilingual fixtures (NEW for the iOS repo's goal #1 — on-device
#      recognition that beats Apple's built-in, especially multilingual):
#      one short clip each in Spanish, German, French, and Russian, rendered
#      with a per-language `say` voice that is actually installed on this
#      machine. These exercise the language-routing / non-Latin paths and give
#      the real-engine Engine Lab (WP3) a reference to compute a loose WER
#      against.
#
# Each fixture is a 16 kHz / mono / 16-bit PCM WAV (Whisper/Parakeet native
# format, so no in-app resampling) paired with an expected-transcript `.txt`.
# The set is small and checked in (self-contained; no submodule dependency).
#
# Determinism: `say` renders from text with a fixed voice + rate, then
# `afconvert` down-samples to 16 kHz mono LEI16. Re-running reproduces the same
# bytes on the same OS/voice. The expected `.txt` is the *spoken* text.
#
# IMPORTANT on the multilingual `.txt`: synthetic TTS is NOT natural speech, so
# a real ASR engine will NOT reproduce the reference verbatim. Tier-1
# (`swift test`) never asserts against these transcripts — it replays the WAVs
# through a scripted engine and asserts on the pipeline. The real-engine
# (WP3 Engine Lab / nightly) suite asserts against them only with a LOOSE WER /
# key-phrase-containment threshold, never exact equality. See fixtures/README.md.
#
# Usage: ./scripts/gen-fixtures.sh [--check]
#   --check   regenerate into a temp dir and diff against the committed set;
#             exits non-zero if the AUDIO FORMAT differs (a CI drift guard).
#             Because `say` output varies across macOS/voice versions, --check
#             compares only format (sample rate / channels / bit depth), never
#             sample bytes.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/fixtures/audio"
COMMITTED_DIR="$ROOT/fixtures/audio"

# English voice (stable US-English), matching the macOS repo's pinned choice.
VOICE="${OPENWHISP_FIXTURE_VOICE:-Samantha}"
RATE="${OPENWHISP_FIXTURE_RATE:-175}"

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

if [[ "$CHECK" == "1" ]]; then
    OUT_DIR="$(mktemp -d)/audio"
fi
mkdir -p "$OUT_DIR"

# --- helpers -----------------------------------------------------------------

# render <text> <out.wav> [voice] [rate]
# say → AIFF → 16 kHz mono LEI16 WAV. `say`'s WAV output can't pin the sample
# rate; afconvert can.
render() {
    local text="$1" out="$2" voice="${3:-$VOICE}" rate="${4:-$RATE}"
    local aiff
    aiff="$(mktemp).aiff"
    say -v "$voice" -r "$rate" -o "$aiff" "$text"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$out"
    rm -f "$aiff"
}

# silence_wav <seconds> <out.wav>
silence_wav() {
    local seconds="$1" out="$2" frames
    frames="$(printf '%.0f' "$(echo "$seconds * 16000" | bc -l)")"
    python3 - "$out" "$frames" <<'PY'
import sys, wave
out, frames = sys.argv[1], int(sys.argv[2])
w = wave.open(out, "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
w.writeframes(b"\x00\x00" * frames)
w.close()
PY
}

# concat_wavs <out.wav> <in1.wav> [in2.wav ...]  (assumes identical format)
concat_wavs() {
    local out="$1"; shift
    python3 - "$out" "$@" <<'PY'
import sys, wave
out, ins = sys.argv[1], sys.argv[2:]
first = wave.open(ins[0], "rb")
params = first.getparams()
frames = [first.readframes(first.getnframes())]
first.close()
for p in ins[1:]:
    w = wave.open(p, "rb")
    frames.append(w.readframes(w.getnframes()))
    w.close()
w = wave.open(out, "wb")
w.setparams(params)
for f in frames:
    w.writeframes(f)
w.close()
PY
}

# emit <name> <transcript> [voice] [rate]  → a WAV plus its .txt sidecar.
emit() {
    local name="$1" transcript="$2" voice="${3:-$VOICE}" rate="${4:-$RATE}"
    render "$transcript" "$OUT_DIR/$name.wav" "$voice" "$rate"
    printf '%s\n' "$transcript" > "$OUT_DIR/$name.txt"
    echo "  ✓ $name.wav ($(du -h "$OUT_DIR/$name.wav" | cut -f1))  [$voice]"
}

# best_voice <lang_prefix> <candidate1> [candidate2 ...]
# Prints the first candidate installed on this machine, else the first `say`
# voice whose locale starts with <lang_prefix>, else empty (skip the fixture).
best_voice() {
    local prefix="$1"; shift
    local installed candidate
    installed="$(say -v '?' 2>/dev/null)"
    for candidate in "$@"; do
        if grep -qF "$candidate " <<<"$installed"; then
            printf '%s' "$candidate"; return 0
        fi
    done
    # Fallback: any installed voice for the locale prefix.
    awk -v p="$prefix" 'index($0, p) { $NF=""; sub(/[ \t]+[a-z]{2}_[A-Z]{2}.*$/,""); print; exit }' \
        <<<"$installed" | sed 's/[[:space:]]*$//'
}

echo "Generating audio fixtures into $OUT_DIR (English voice=$VOICE rate=$RATE)…"

# ============================================================================
# 1) English pipeline fixtures (ported from the macOS repo)
# ============================================================================

emit "plain_speech" "The quick brown fox jumps over the lazy dog."

emit "numbers_dates" "Call me at four fifteen on March third about the twelve hundred dollar invoice."

# Speech then a long silence tail — silence auto-stop / VAD finalization.
tmp_speech="$(mktemp).wav"; tmp_sil="$(mktemp).wav"
render "This sentence is followed by two seconds of silence." "$tmp_speech"
silence_wav 2.0 "$tmp_sil"
concat_wavs "$OUT_DIR/speech_then_silence.wav" "$tmp_speech" "$tmp_sil"
printf '%s\n' "This sentence is followed by two seconds of silence." \
    > "$OUT_DIR/speech_then_silence.txt"
rm -f "$tmp_speech" "$tmp_sil"
echo "  ✓ speech_then_silence.wav ($(du -h "$OUT_DIR/speech_then_silence.wav" | cut -f1))"

# Two utterances separated by a pause — pause-based chunker splits into two.
a="$(mktemp).wav"; b="$(mktemp).wav"; g="$(mktemp).wav"
render "First utterance." "$a"
silence_wav 1.0 "$g"
render "Second utterance." "$b"
concat_wavs "$OUT_DIR/two_utterances.wav" "$a" "$g" "$b"
printf '%s\n' "First utterance. Second utterance." > "$OUT_DIR/two_utterances.txt"
rm -f "$a" "$b" "$g"
echo "  ✓ two_utterances.wav ($(du -h "$OUT_DIR/two_utterances.wav" | cut -f1))"

# Pure silence — the "nothing was said" path (empty outcome).
silence_wav 1.5 "$OUT_DIR/silence.wav"
printf '' > "$OUT_DIR/silence.txt"
echo "  ✓ silence.wav ($(du -h "$OUT_DIR/silence.wav" | cut -f1))"

# ============================================================================
# 2) Multilingual fixtures (goal #1 — beat Apple on multilingual)
#    One short clip per language, using whatever per-language voice is installed.
#    Skips a language cleanly if no voice is present (documented in the README).
# ============================================================================

echo "Generating multilingual fixtures (voices resolved from 'say -v ?')…"

# Spanish
es_voice="$(best_voice es_ Mónica Paulina "Eddy (Spanish (Spain))")"
if [[ -n "$es_voice" ]]; then
    emit "spanish_greeting" "Hola, me llamo Ana y vivo en Madrid con mi familia." "$es_voice"
else
    echo "  – skipped spanish_greeting (no Spanish voice installed)"
fi

# German
de_voice="$(best_voice de_ Anna "Eddy (German (Germany))")"
if [[ -n "$de_voice" ]]; then
    emit "german_greeting" "Guten Tag, ich heiße Peter und komme aus Berlin." "$de_voice"
else
    echo "  – skipped german_greeting (no German voice installed)"
fi

# French
fr_voice="$(best_voice fr_ Jacques Amélie "Eddy (French (France))")"
if [[ -n "$fr_voice" ]]; then
    emit "french_greeting" "Bonjour, je m'appelle Marie et j'habite à Paris." "$fr_voice"
else
    echo "  – skipped french_greeting (no French voice installed)"
fi

# Russian (non-Latin script — the language-guard / Cyrillic path)
ru_voice="$(best_voice ru_ Milena)"
if [[ -n "$ru_voice" ]]; then
    emit "russian_greeting" "Здравствуйте, меня зовут Иван, я живу в Москве." "$ru_voice"
else
    echo "  – skipped russian_greeting (no Russian voice installed)"
fi

echo "Done. $(ls "$OUT_DIR"/*.wav | wc -l | tr -d ' ') WAV fixtures."

# ============================================================================
# --check: format-drift guard (compares audio format only, not bytes)
# ============================================================================
if [[ "$CHECK" == "1" ]]; then
    echo ""
    echo "Checking committed fixtures' format against a fresh render…"
    fail=0
    for wav in "$OUT_DIR"/*.wav; do
        name="$(basename "$wav")"
        committed="$COMMITTED_DIR/$name"
        if [[ ! -f "$committed" ]]; then
            echo "  ✗ $name missing from committed set"; fail=1; continue
        fi
        fresh_fmt="$(afinfo "$wav" 2>/dev/null | grep -E 'Data format|Channels|sample rate' || true)"
        comm_fmt="$(afinfo "$committed" 2>/dev/null | grep -E 'Data format|Channels|sample rate' || true)"
        if [[ "$fresh_fmt" != "$comm_fmt" ]]; then
            echo "  ✗ $name format drift"; fail=1
        else
            echo "  ✓ $name format matches"
        fi
    done
    # Also flag committed fixtures that the current run did not (re)produce —
    # e.g. a multilingual fixture whose voice is no longer installed.
    for committed in "$COMMITTED_DIR"/*.wav; do
        name="$(basename "$committed")"
        [[ -f "$OUT_DIR/$name" ]] || { echo "  ! $name committed but not regenerated (voice missing?)"; }
    done
    exit "$fail"
fi
