# Testing — the contract for `openwhisp-ios`

Same law as the macOS repo: **every feature ships with an automated test, and
`swift test` on `OpenWhispMobileKit` is the always-green gate.** This doc is the
tiered testing contract — what each tier covers, the exact command to run it,
and what runs in CI vs. locally/nightly.

The tiers mirror the macOS repo's proven approach
([openwhisp `docs/E2E_AUDIO_TESTING.md`](https://github.com/initcore0/openwhisp/blob/main/docs/E2E_AUDIO_TESTING.md)):
fast deterministic logic tests first, real hardware/engines last.

## The tiers at a glance

| Tier | What it proves | Command | Where it runs |
|---|---|---|---|
| **1. `swift test` gate** | All pure logic: `CaptureFlow`, `MicKeyResolver`, `TranscriptInsertPolicy`, handoff store, layout/autocap, sync `plan()`. Deterministic, ~seconds, no simulator. | `./scripts/test.sh` | **CI (blocking)** + every local commit |
| **1b. Fixture integrity** | The checked-in `fixtures/audio/*.wav` are 16 kHz/mono/16-bit and each has a `.txt` reference; the required English + multilingual set is present. | `./scripts/check-fixtures.sh` | **CI (blocking)** |
| **2. Simulator XCUITest** | The app bundle builds, installs, launches, and renders; text entry works via the system keyboard. | `./scripts/uitest.sh` | **CI (separate job)** + local |
| **3. Env-gated real-engine runs** | Real Parakeet/WhisperKit engines transcribe `fixtures/audio/*.wav` on a simulator (loose WER). Downloads models on first run. | `OPENWHISP_E2E_ENGINES=1 ./scripts/e2e-engines-sim.sh` | **Local / nightly (not blocking)** |
| **4. Real-device checklist** | Hero-flow spikes, memory/latency/thermals, keyboard-extension enablement, cross-device sync — things a simulator cannot prove. | Manual (see below) | Human, pre-release |

### Tier 1 — the `swift test` gate

```sh
./scripts/test.sh          # swift test on Packages/OpenWhispMobileKit
```

The workhorse. Fixture WAVs are replayed here through the pipeline with a
**scripted** engine (canned text) so assertions are exact and independent of ASR
accuracy — see the macOS `FeatureMatrixE2ETests` pattern. Real-engine replay
lives in Tier 3, not here. Anything you can express as pure logic belongs in
this tier; if a feature's logic is trapped on an AppKit/UIKit shell, extract a
pure resolver into `MobileCore`/`KeyboardCore` first (the macOS repo's
`ProfileResolver`/`LanguageResolver` move).

### Tier 1b — fixture integrity

```sh
./scripts/check-fixtures.sh    # validate the committed fixtures (no `say` needed)
./scripts/gen-fixtures.sh      # regenerate them (macOS only; needs `say`)
./scripts/gen-fixtures.sh --check   # format-drift guard
```

`check-fixtures.sh` uses pure `python3` to read each WAV header, so it runs
anywhere (including a Linux CI box) without macOS audio tools. It fails CI if a
fixture is corrupt, in the wrong format, missing its `.txt` sidecar, or if the
required English set / all multilingual fixtures are absent. Provenance and the
**loose-WER expectations** for the synthetic multilingual clips are documented
in [`fixtures/README.md`](../fixtures/README.md) — synthetic TTS is not natural
speech, so real-engine assertions on these use loose WER / key-phrase
containment only.

### Tier 2 — simulator XCUITest

```sh
./scripts/uitest.sh                    # both suites on the default simulator
./scripts/uitest.sh OpenWhispUITests   # just the host-app smoke
OPENWHISP_SIM_DEVICE="iPhone 17 Pro" OPENWHISP_SIM_OS="26.5" ./scripts/uitest.sh
```

To just *see* the app on a simulator (build + install + launch, no tests):

```sh
./scripts/run-sim.sh    # opens Simulator.app, launches the host app, drops a
                        # screenshot at .build/run-sim-launch.png
```

The host app launched on an iPhone 17 (iOS 26.5) simulator via `run-sim.sh`:

![OpenWhisp host app on the simulator](assets/simulator-home.png)

Two suites:

- **`OpenWhispUITests`** (`Apps/UITests/HostSmoke/`) — launches the **real host
  app** and asserts the placeholder home renders (nav title, the
  `LabeledContent` status/bundle/version rows). This is the end-to-end proof the
  bundle installs, links `OpenWhispMobileKit`, and reaches its first screen —
  the layer `swift test` can't cover.
- **`UITestHostUITests`** (`Apps/UITests/Typing/`) — types `Hello, world!` into a
  text field with the **system keyboard** and asserts it lands. It targets a
  tiny dedicated harness app (`Apps/UITests/Host/`, target `UITestHost`), not the
  shipping host app, so the test is deterministic and can't drift as the host UI
  evolves.

**Why the typing test does NOT enable our keyboard extension.** Enabling a
custom keyboard programmatically via XCUITest — driving Settings ▸ General ▸
Keyboard ▸ Keyboards ▸ Add New Keyboard, then toggling **Allow Full Access** — is
notoriously flaky across iOS versions and simulator states (the Settings UI
hierarchy shifts, Full-Access toggles present confirmation alerts, and the
switch doesn't always take on a fresh simulator). Shipping that as a CI test
would trade a real signal for intermittent red. So Tier 2 proves **system**
text entry (the prerequisite plumbing), and **our keyboard extension is
validated on a real device via the Tier-4 checklist** below. When WP4/WP5 add
keyboard behavior, its *logic* is tested in `KeyboardCoreTests` (Tier 1); only
the on-device enablement + insertion is manual.

### Tier 3 — env-gated real-engine runs

```sh
OPENWHISP_E2E_ENGINES=1 ./scripts/e2e-engines-sim.sh
```

Runs the package tests on a **simulator** destination (real Parakeet/WhisperKit
link CoreML and cannot run in the Foundation-only `swift test` gate) with
`OPENWHISP_E2E_ENGINES=1` exported, so the engine tests the WP3 agent adds
(replaying `fixtures/audio/*.wav` through the real streaming/file engines)
execute. Without the env var those tests skip and the script is a green no-op.

**⚠️ First run downloads model weights** (Parakeet variants / WhisperKit
tiny·base·small) from the network, cached thereafter — expect minutes and
bandwidth on the first invocation. That's why this tier is **local/nightly, not
the blocking CI gate.** Assert against `fixtures/*.txt` only with **loose WER /
key-phrase containment** (see `fixtures/README.md`), never exact equality —
ANE/GPU float non-associativity makes transcripts differ across machines.

### Tier 4 — real-device checklist (manual, pre-release)

A simulator cannot exercise the microphone, the Neural Engine, background-capture
intents, custom-keyboard enablement, thermals, or a paired Mac. These are
human-run on a physical iPhone (iOS 18+). Build/run on device with a team:

```sh
DEVELOPMENT_TEAM=XXXXXXXXXX xed .    # then Run on your iPhone in Xcode
```

(see the **Device builds** note in [../README.md](../README.md) — the generated
project carries the literal `${DEVELOPMENT_TEAM}` build setting, so Xcode only
resolves a team when launched with the env var).

#### WP2 R0 spike checklist (the risk burndown — run BEFORE hero-flow work)

From [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) §WP2. Record verbatim
pass/fail per cell into `docs/SPIKE_RESULTS.md`:

- **R0a — background capture-start.** A minimal `AudioRecordingIntent` starts
  `AVAudioEngine` capture + a Live Activity. Matrix: app **foregrounded /
  backgrounded / not running** × trigger **Action button / Control Center /
  Shortcuts**. For each cell: did capture actually start? Record the failure
  mode verbatim. *Gate:* if background-start fails, the hero flow degrades to the
  app-switch floor flow and marketing copy adjusts.
- **R0b — keyboard→host trigger.** (a) Walk the manual app-switch UX end to end.
  (b) Test the responder-chain `openURL:` hack — does it compile and work on
  iOS 18/26? Note the App-Review risk regardless of whether it works ([C9]).
  *Gate:* decision recorded in `ARCHITECTURE.md` §5 before WP5.
- **R0c — round-trip insert.** Publish a `PendingTranscript` from the host →
  Darwin notification while the keyboard is live (measure insert latency + miss
  rate over 20 trials); and App-Group read on keyboard reappear after an
  app-switch (20 trials). *Gate:* confirms the store-read fallback + 120 s expiry
  mitigations hold.

#### Keyboard-extension enablement (manual — the flaky path Tier 2 skips)

1. Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard ▸ **OpenWhisp**.
2. Type in Notes/Safari with Full Access **OFF** — the keyboard must be fully
   functional as a plain keyboard (guideline 4.4.1). Confirm globe switches out.
3. Enable **Allow Full Access**; confirm the App-Group handoff + dictation
   affordance behave per `MicKeyResolver`.

#### Engine benchmark matrix (WP3) & sync (WP6)

- **Benchmarks:** peak RSS, time-to-first-token, real-time factor, thermal state
  for the candidate models on ≥2 real devices → `docs/BENCHMARKS.md`; picks the
  `recommendedDefault(for:)` table. Keyboard extension idle RSS must stay under
  budget (WP4).
- **Sync:** edit vocabulary on the Mac → sync → phone dictation applies it;
  history flows both ways — against a real paired Mac.

## What runs in CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml), macOS runner, on every
push/PR:

| Job | Tier | Blocking |
|---|---|---|
| `package-tests` | 1 (`./scripts/test.sh`) | ✅ yes |
| `fixtures` | 1b (`./scripts/check-fixtures.sh`) | ✅ yes |
| `simulator-build` | builds all three product targets unsigned | ✅ yes |
| `simulator-uitest` | 2 (`./scripts/uitest.sh`) — separate job so a UI-test flake is attributable and doesn't mask a logic regression | ✅ yes (own job) |

**Not in CI:** Tier 3 (downloads models, minutes-long — nightly/local) and
Tier 4 (needs real hardware). The simulator UI-test job is a **separate** job
from `package-tests` on purpose: if the simulator flakes, you can tell it apart
from a real logic failure at a glance.

## Adding a test for a new feature (the rule of thumb)

1. **Pure logic first.** Put the decision in a Foundation-only type in
   `MobileCore`/`KeyboardCore` and unit-test it (Tier 1). If it's trapped on a
   UIKit/SwiftUI shell, extract a resolver first.
2. **Drive it from a fixture** if it touches the audio pipeline — replay a WAV
   through the pipeline with a scripted engine and assert the observable effect.
   Add a new fixture (+ `.txt`) to `scripts/gen-fixtures.sh` if needed, then
   `./scripts/check-fixtures.sh`.
3. **Real engine / real device only if the feature demands it** — add to Tier 3
   (`e2e-engines-sim.sh`) or the Tier-4 checklist.

A feature without a test is not done.
