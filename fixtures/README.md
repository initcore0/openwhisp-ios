# Audio test fixtures

16 kHz / mono / 16-bit PCM WAVs (the Whisper/Parakeet native format — no in-app
resampling) used by the iOS E2E audio-testing suite. See
[docs/TESTING.md](../docs/TESTING.md).

Each `*.wav` pairs with a `*.txt` holding the **spoken** text. They are checked
in (not generated at build time) so the suite is self-contained on any machine
and in CI.

## Provenance

All fixtures are synthesized locally with macOS `say` + `afconvert` — there is
**no third-party or copyrighted audio** in this repo.

- The **English pipeline fixtures** are ported verbatim from the macOS OpenWhisp
  repo's `Tests/Fixtures/audio/` (generator: `scripts/gen-audio-fixtures.sh`
  there). They exercise the streaming/chunking/VAD/formatting pipeline and use
  the pinned US-English voice `Samantha` at 175 wpm.
- The **multilingual fixtures** are NEW to the iOS repo, added for product
  goal #1: on-device recognition that beats Apple's built-in dictation,
  *especially multilingual*. Each is one short clip rendered with a
  per-language `say` voice that is actually installed on the generating machine
  (resolved at generate time — see "Voice resolution" below).

Regenerate the whole set with:

```bash
./scripts/gen-fixtures.sh          # rewrite the set
./scripts/gen-fixtures.sh --check  # CI drift guard (audio format only)
```

## The English pipeline fixtures

| Fixture | Voice | Duration | What it exercises |
|---|---|---|---|
| `plain_speech.wav` | Samantha | ~2.5 s | Streaming-transcription baseline (continuous speech). |
| `numbers_dates.wav` | Samantha | ~4.0 s | Smart-formatting (numbers, times, dates, currency). |
| `speech_then_silence.wav` | Samantha | ~5.0 s | Silence auto-stop / VAD finalization (speech + 2 s silence tail). |
| `two_utterances.wav` | Samantha | ~3.0 s | Pause-based chunker splitting into two utterances (1 s gap). |
| `silence.wav` | — | 1.5 s | The "nothing was said" path (empty outcome; pure digital silence). |

## The multilingual fixtures (goal #1)

| Fixture | Language | Voice used¹ | Reference text |
|---|---|---|---|
| `spanish_greeting.wav` | Spanish (es) | Mónica (es_ES) | Hola, me llamo Ana y vivo en Madrid con mi familia. |
| `german_greeting.wav` | German (de) | Anna (de_DE) | Guten Tag, ich heiße Peter und komme aus Berlin. |
| `french_greeting.wav` | French (fr) | Jacques (fr_FR) | Bonjour, je m'appelle Marie et j'habite à Paris. |
| `russian_greeting.wav` | Russian (ru) | Milena (ru_RU) | Здравствуйте, меня зовут Иван, я живу в Москве. |

¹ The voice recorded above is what was installed when the committed set was last
generated. `scripts/gen-fixtures.sh` re-resolves the best installed voice per
language at generate time (`say -v ?`), and **skips a language cleanly** if no
voice for it is installed — so a machine missing, say, the Russian voice will
regenerate the other three and print a `– skipped russian_greeting` line rather
than fail. If you regenerate on such a machine, do not commit the deletion of a
fixture you simply couldn't render.

The Russian clip is deliberately non-Latin (Cyrillic): it exercises the
language-guard / script-detection path that the macOS repo learned the hard way
(tiny local models translate non-Latin dictations — see the macOS
`RefineOutputGuard`).

## How the `.txt` references are used (READ THIS before asserting on them)

**Synthetic TTS is not natural speech.** A real ASR engine will *not* reproduce
these references verbatim — TTS prosody, the absence of natural disfluencies,
and voice-model artifacts all move the output. So:

- **Tier 1 (`swift test`)** never asserts a fixture against its `.txt`. It
  replays the WAV through `FileAudioReplay` + a **scripted** engine (canned
  text) and asserts on the *pipeline* (chunk count, ordering, VAD
  finalization, formatting, handoff). Deterministic and exact — independent of
  any ASR accuracy.
- **Real-engine runs (WP3 Engine Lab / nightly)** may assert against the `.txt`,
  but only with a **loose Word Error Rate** threshold or key-phrase
  containment — never exact string equality. Recommended loose bounds for these
  synthetic clips (tune once real engines land in WP3):
  - English clips: WER ≤ ~10 % (normalized: lowercase, strip punctuation).
  - Multilingual clips: WER ≤ ~25–35 %, or assert containment of 2–3 anchor
    tokens (e.g. Spanish `madrid`, German `berlin`, French `paris`, Russian
    `москве`). Treat these as **smoke checks that the engine produced text in
    the right language/script**, not accuracy benchmarks. Natural-speech WER
    benchmarking belongs on real recordings gathered in WP3, not on TTS.

## Determinism note

`say` renders from text with a fixed voice + rate; `afconvert` down-samples to
16 kHz mono LEI16. Re-running reproduces the same bytes on the same OS/voice
version, but sample bytes can drift across macOS/voice releases — so
`gen-fixtures.sh --check` compares only the audio *format* (sample rate /
channels / bit depth), which is all the pipeline cares about.
