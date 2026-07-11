# Engine Lab

The Engine Lab is OpenWhisp iOS's **product Goal #1 instrument**: the screen where
"on-device recognition is provably better than Apple's, especially multilingual"
stops being a claim and becomes a measured number.

It lives at **Settings → Developer → Engine Lab** (a developer surface, not a
first-run feature).

## What it does

For a chosen fixture (or a live-mic utterance) and a chosen engine, the Lab:

1. **Runs the audio** through any installed engine via the upstream
   `FileTranscriptionEngine` seam:
   - a **Parakeet** variant (`ParakeetMobileFileEngine`, TDT v3 batch),
   - a **WhisperKit** model (`WhisperKitMobileFileEngine`),
   - or the **Apple baseline** (`AppleSpeechBaselineEngine`,
     `SFSpeechRecognizer`, on-device only — benchmark baseline, never production).
   The engine to run is whatever is selected in **Settings** (the Lab is honest
   about that in its "Active engine" section).
2. **Scores the transcript** against the fixture's reference with the pure
   `MobileCore.WordErrorRate` util: a Wagner–Fischer word alignment giving
   substitutions / deletions / insertions, WER = (S+D+I)/N, and a word-level diff
   token stream. The diff is rendered as colored chips (orange = substitution,
   red = insertion, blue strike = deletion) so you see exactly what each engine got
   wrong. Normalization is case- and punctuation-insensitive and Unicode-aware
   (Cyrillic/accented Latin tokenize correctly — the multilingual fixtures are the
   whole point).
3. **Reports metrics** (`MobileCore.LabMetrics`): latency (wall-clock), realtime
   factor (latency / audio duration), and a peak-RSS **delta** (before/after
   `phys_footprint` via `task_info`).
4. **Compare mode** runs the SAME fixture through the selected OpenWhisp engine AND
   the Apple baseline, then states a one-line verdict via `MobileCore.LabVerdict`:
   `"OpenWhisp WER 4.2% vs Apple 11.8% — OpenWhisp wins."` When Apple has no
   on-device model for the language, the Lab says so honestly
   (`.baselineUnavailable`) rather than claiming a bogus 0% — a real data point for
   the multilingual coverage-gap story.
5. **Live-mic mode** dictates a real utterance through the active engine and reports
   the transcript + latency/RSS (no reference → no WER).
6. **Persists the last N runs** (`LabRunLog`, capped at 100, newest-first) as
   `lab-runs.json` in Application Support, exportable as pretty JSON via ShareLink.

The scoring, verdict, fixture catalog, and retention rule are all pure
`MobileCore` and unit-tested on the `swift test` gate
(`WordErrorRateTests`, `LabVerdictTests`, `LabFixtureCatalogTests`, `LabRunTests`).
The OS-bound orchestration (`LabRunner`, in CaptureKit) is covered for its
deterministic pieces by `LabRunnerTests`, with the real model path behind the
env-gated `RealEngineE2ETests` (`OPENWHISP_E2E_ENGINES=1`).

## Fixtures & bundle size

The Lab's benchmark WAVs are the repo's `fixtures/audio/` (5 English/neutral +
4 multilingual: French, German, Spanish, Russian), each paired with a reference
`.txt`.

**Bundling choice: Debug-only.** The fixtures are bundled as a folder-reference
resource on the host app (they appear in the app bundle under `audio/`). To keep
the **Release** app size sane, a Release-config **post-build script** strips the
`audio/` fixtures out of the built product (`project.yml → OpenWhisp target →
postBuildScripts`). So:

- **Debug builds** carry the fixtures → the fixture Lab works.
- **Release builds** ship without them → the "No fixtures bundled" state shows, and
  only the live-mic Lab is available.

This was chosen over on-demand download (the fixtures are tiny and deterministic;
a download would add a network path we don't want) and over always-bundling (it
would bloat the shipped app with developer-only benchmark data). Verified:
`Debug` build bundles 9 WAV + 9 TXT; `Release` build bundles 0.

The Lab resolves fixtures with `Bundle.main.url(...subdirectory: "audio")` (falling
back to `Fixtures`/flat lookups), and only lists what's actually present — so a
Release build degrades gracefully.

## Apple baseline & privacy

`AppleSpeechBaselineEngine` forces `requiresOnDeviceRecognition = true`: nothing
leaves the device. It is the ONLY code that touches `SFSpeechRecognizer`, it is
reachable only from the Lab, and it requires an explicit speech-recognition
authorization. The `NSSpeechRecognitionUsageDescription` string states plainly that
it is used only by the developer Engine Lab to benchmark against Apple's on-device
recognizer (see ARCHITECTURE §7).
