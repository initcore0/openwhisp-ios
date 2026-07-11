# CaptureKitTests

Two tiers, mirroring the working agreement:

## 1. Always-green (`swift test`) — no network, models, mic, or simulator

- **`CaptureCoordinatorTests`** — drives `CaptureCoordinator` (and the pure
  `CaptureFlow` state machine) end-to-end with protocol fakes
  (`FakeStreamingEngine`, `FakeAudioSession`, `FakeNotifier`) + an
  `InMemoryHandoffStore`. Asserts the §6.2 contract: the **published text is the
  CLEANED text** (raw `"gpt is great"` → cleaned `"GPT is great."`, so raw text
  reaching publish fails loudly), and **cancel / interruption / engine-error /
  empty-transcript paths never publish**.
- **`EngineSupportTests`** — the ported `AudioLevelMath` curve fidelity (the VAD is
  calibrated to these exact constants) and the `IOSModelProvisioning`
  `recommendedDefault` table + Parakeet classification / coarse state.

These run on the macOS `swift test` host (the package declares `.macOS(.v14)` for
exactly this — it ships no macOS product). AVAudioSession-only code
(`IOSAudioCapture`, `AudioSessionBridge`, `IOSAudioSessionController`) is
`#if os(iOS)`-guarded so the host build stays green.

## 2. Opt-in real-engine E2E — needs a model download + GPU/ANE host

- **`RealEngineE2ETests`** — runs an ACTUAL engine (Parakeet TDT v3 file engine by
  default; `OPENWHISP_E2E_ENGINE=whisperkit` for WhisperKit) over a fixture WAV and
  asserts the transcript. **Skipped unless `OPENWHISP_E2E_ENGINES=1`** because it
  downloads a ~600 MB CoreML model on first run and needs a Metal/ANE-capable host.

```bash
# default: Parakeet TDT v3 file engine
OPENWHISP_E2E_ENGINES=1 swift test --filter RealEngineE2ETests

# WhisperKit file engine instead
OPENWHISP_E2E_ENGINES=1 OPENWHISP_E2E_ENGINE=whisperkit swift test --filter RealEngineE2ETests

# a custom fixture (defaults to the bundled Fixtures/plain_speech.wav)
OPENWHISP_E2E_ENGINES=1 OPENWHISP_E2E_FIXTURE=/path/to.wav swift test --filter RealEngineE2ETests
```

The testing infra (which owns `scripts/`) can wrap this in a `scripts/e2e-engines-sim.sh`;
this target intentionally does not create that script (out of ownership scope).
