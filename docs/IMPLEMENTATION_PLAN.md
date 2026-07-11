# OpenWhisp iOS — Implementation Plan

> Prereq reading for every work package: [ARCHITECTURE.md](ARCHITECTURE.md)
> (interfaces are binding) and [RESEARCH.md](RESEARCH.md) (platform
> constraints [C1]–[C11]). Each WP below is sized to be dispatched to an
> autonomous agent as a self-contained brief: it names its repo, inputs,
> deliverables, and an acceptance gate. **No WP is done without its tests.**

## Dependency graph

```
WP0 (upstream: core consumable on iOS) ──┬──▶ WP3 (host dictation composer, iM0)
WP1 (scaffold this repo) ────────────────┤          │
WP2 (R0 device spikes)  ─────────────────┼──▶ WP5 (handoff + hero flow, iM2)
                                         │          ▲
WP4 (keyboard, iM1) ─────────────────────┴──────────┘
WP0b (upstream: sync verbs + updatedAt) ──▶ WP6 (P2P sync, iM3) ──▶ WP7 (MCP client, iM4)
WP5 + WP6 ──▶ WP8 (polish, iM5) ──▶ WP9 (App Store release)
```

WP0, WP1, WP2 can run **in parallel** (different repos / real device).
WP3 and WP4 can run in parallel after their prereqs.

---

## WP0 — Upstream: make `OpenWhispCore` consumable from iOS

**Repo:** `openwhisp` (macOS). **Blocked by:** nothing. **Blocks:** WP3+.

- Add `.library(name: "OpenWhispCore", targets: ["OpenWhispCore"])` and
  `.library(name: "OpenWhispBridgeKit", targets: ["OpenWhispBridgeKit"])`
  products to `Package.swift`; add `.iOS(.v18)` to `platforms`.
- Promote to `public` (with explicit inits where memberwise inits are relied
  on): `SmartFormatter`, `Vocabulary`(+`Substitution`, store), `TranscriptCleaner`,
  `PostProcessor`/`PostProcessContext`/`PostProcessorChain`, `MetaInstructionStripper`,
  `AppProfile`(+store, `ProfileResolver`, `ModeResolver`, `LanguageResolver`),
  `TranscriptionHistory` types, `ConfigBundle`/`ConfigPack`, `PrivacyStatus`,
  `RefineFlow`, `InstructionChain`, `RefineOutputGuard`, `DictationSession` types,
  `AudioCapture`, `TextOutput` (enums only — protocol itself is mac-shaped, see note),
  `TranscriptionEngine` protocols, `WhisperKitModelCatalog`, `WhisperKitBridge`'s
  pure mapper, `SecretStore`, and the Parakeet core types (`ParakeetCatalog`,
  `ParakeetLanguageGate`, `ParakeetLanguageHint`, `ParakeetDownloadState`/policy,
  `StreamingRoutePolicy`, `AgentEouAutoStop`).
- Platform-guard mac-isms inside core files: `CoreAudio.AudioDeviceID` in
  `WhisperKitBridge`/`StreamingTranscriptionEngine.selectDevice` → introduce
  `public typealias AudioDeviceHandle` (`AudioDeviceID` on macOS, `String`
  route UID on iOS) or `#if os(macOS)` the member; audit the ~110-file
  allowlist for other `canImport` breaks by actually building for iOS.
- CI: add a job that builds both library products for an iOS destination
  (`xcodebuild -scheme OpenWhispCore -destination 'generic/platform=iOS' build`
  or `swift build` with a downloaded iOS SDK destination — pick what works on
  the runner).

**Acceptance:** upstream `swift test` green (no behavior change);
iOS-destination build green in CI; `openwhisp-ios` can `import OpenWhispCore`
via a branch dependency. **Deliverable:** one PR to `openwhisp`.

## WP0b — Upstream: sync verbs + `updatedAt` stamps (wire v1.1, schema v3)

**Repo:** `openwhisp`. **Blocked by:** WP0. **Blocks:** WP6.

- `BridgeWire`: add `sync.manifest` / `sync.pull` / `sync.push` methods with
  typed params/results per ARCHITECTURE §6.5; add `sync` capability; keep v1
  clients working (capability-gated).
- `ConfigBundle` schema v3: `updatedAt` on `Vocabulary.Substitution`,
  `AppProfile`, and modes; decode fallback for v2 (missing stamps → epoch).
- `BridgeRouter` routing + validation for the new verbs; handlers stubbed
  behind the existing `AgentBridgeHost` protocol (Mac-side real handlers land
  in WP6-mac).
- Tests: wire round-trip for each new verb, v2→v3 decode fallback, router
  validation/limits — in `OpenWhispCoreTests`.

**Acceptance:** upstream `swift test` green; wire docs updated
(docs/AGENT_BRIDGE.md). **Deliverable:** one PR to `openwhisp`.

## WP1 — Scaffold this repo

**Repo:** `openwhisp-ios`. **Blocked by:** nothing (uses WP0 branch dep when ready).

- `Packages/OpenWhispMobileKit` SwiftPM package: targets `MobileCore`,
  `CaptureKit`, `SyncKit`, `KeyboardCore` + test targets, per ARCHITECTURE §2.
  Dependency on `initcore0/openwhisp` `.branch("main")` (behind a local-path
  override for development: `Package.swift` honors
  `OPENWHISP_CORE_PATH` or a `Package.local.swift` pattern — document it).
- `project.yml` (XcodeGen): targets `OpenWhisp` (app), `OpenWhispKeyboard`
  (keyboard extension, `RequestsOpenAccess: YES`), `OpenWhispWidgets`
  (widgets/Live Activity). Entitlements: App Group `group.app.openwhisp.ios`
  on all three; bundle IDs per D10; iOS 18.0 deployment target; `.xcodeproj`
  git-ignored; `scripts/bootstrap.sh` runs xcodegen.
- Empty-but-compiling app shells (a SwiftUI "hello" host view; keyboard
  extension that shows a placeholder view; widgets stub). **No feature code.**
- Define the MobileCore/KeyboardCore interface files from ARCHITECTURE §6 as
  Swift protocols/types with doc comments (types compile; no conformers yet
  beyond `InMemoryHandoffStore` for tests).
- CI (GitHub Actions, macOS runner): `swift test` on the package + xcodegen +
  `xcodebuild build` all targets + one simulator XCUITest smoke.

**Acceptance:** CI green; app installs on simulator; keyboard extension
appears in Settings and shows its placeholder. **Deliverable:** one PR.

## WP2 — R0 real-device spikes (the risk burndown)

**Repo:** `openwhisp-ios`, branch `spike/r0` (throwaway code, keep the report).
**Blocked by:** WP1 (scaffold). **Blocks:** WP5's shape. **Needs:** a physical
iPhone (iOS 18+) + human-in-the-loop for on-device runs — the agent prepares
the harness and the checklist; the human executes and reports observations.

- **R0a:** minimal `AudioRecordingIntent` that starts `AVAudioEngine` capture +
  a Live Activity. Matrix: app foregrounded / backgrounded / not running ×
  Action button / Control Center / Shortcuts. Record failure modes verbatim.
- **R0b:** keyboard→host trigger. (a) manual app-switch UX walk-through;
  (b) the responder-chain `openURL:` hack — does it compile/work on iOS 18/26?
  Note App-Review risk regardless of whether it works [C9].
- **R0c:** round-trip insert: publish from host → Darwin notification while
  keyboard is live; and App-Group read on keyboard reappear after app-switch.
  Measure latency and miss rate over 20 trials each.

**Acceptance:** `docs/SPIKE_RESULTS.md` with pass/fail per cell + a decision
section that updates ARCHITECTURE §5 (hero viable? mic-key behavior?).
**Deliverable:** report PR (spike code may merge disabled or be discarded).

## WP3 — Host app: on-device dictation composer (iM0)

**Repo:** `openwhisp-ios`. **Blocked by:** WP0 + WP1. **Parallel with:** WP4.

- `IOSAudioCapture: AudioCapture` (AVAudioSession `.playAndRecord` +
  AVAudioEngine tap, route/interruption handling, VAD/RMS reusing core math).
- `ParakeetMobileEngine: StreamingTranscriptionEngine` (FluidAudio; default
  variant `nemotron-multilingual-1120ms`, English fast path
  `parakeet-unified-320ms`) + `ParakeetMobileFileEngine` (TDT v3) — the
  PRIMARY engine per D5, reusing the upstream Parakeet core types.
- `WhisperKitMobileEngine: StreamingTranscriptionEngine` (+ file engine for
  fixtures), reusing `WhisperKitBridge`/`WhisperKitModelCatalog` — secondary,
  ~100-language long tail.
- **Engine Lab** (debug screen in the host app): engine/variant picker, live
  dictation and fixture-WAV runs, side-by-side comparison against an
  `AppleSpeechBaselineEngine` (SFSpeechRecognizer/SpeechAnalyzer, baseline
  only), with per-run metrics (latency, RTF, peak RSS, WER vs. reference
  text) — this is how "better than Apple" gets measured, by us and by users.
- `ModelProvisioning` conformer + model manager UI (download/delete/progress;
  decide bundled-`tiny` vs download-on-first-run after measuring app size).
- `CaptureFlow` state machine (MobileCore) + `CaptureCoordinator` (CaptureKit)
  wiring capture → engine → `SilenceAutoStop` → `TranscriptCleaner` (with
  `Vocabulary`) → composer text.
- Host UI: onboarding (mic permission, model pick), dictation composer
  (record button, waveform from levels, live partials, copy/share), settings
  skeleton, history list backed by `TranscriptionHistory`.
- `scripts/benchmark.sh` + in-app debug screen: peak RSS, time-to-first-token,
  real-time factor, thermal state for tiny/base/small; run on ≥2 real devices,
  results into `docs/BENCHMARKS.md`; pick `recommendedDefault(for:)` table.

**Tests (gate):** CaptureFlow exhaustive unit tests; fixture-WAV → cleaner
pipeline tests (port relevant `FeatureMatrixE2ETests` cases); engine tested
against fixtures on simulator. **Acceptance:** dictate → clean text → copy on
a real device; benchmarks documented; `swift test` green.

## WP4 — Keyboard extension: a real keyboard (iM1)

**Repo:** `openwhisp-ios`. **Blocked by:** WP1. **Parallel with:** WP3.

- `KeyboardLayoutModel` in KeyboardCore (pure): letters/symbols/numbers pages,
  shift/capsLock/autocap state machine, backspace repeat, space double-tap →
  period, return-key label pass-through. English QWERTY v1 (D4).
- Extension UI: dumb key rendering from the model, touch handling → `KeyAction`,
  haptics (only where extensions are allowed), light/dark, iPhone + iPad size
  classes, globe key (`needsInputModeSwitchKey`).
- `ProxyTextSink: KeyboardTextSink` over `UITextDocumentProxy`.
- Mic key present but resolved by `MicKeyResolver` → with no host features yet
  it shows the "set up dictation" explainer (and the Full-Access explainer
  when off). **Typing must be 100% functional with Full Access OFF** [C8].
- Memory budget guard: measure extension peak RSS in Instruments; document in
  `docs/BENCHMARKS.md`; fail the WP if idle > 25 MB.

**Tests (gate):** layout/shift/autocap truth-table tests in KeyboardCoreTests;
MicKeyResolver full truth table; XCUITest: enable keyboard, type "Hello,
world!" into a test field, switch pages, globe out. **Acceptance:** usable as
a daily plain keyboard on device; 4.4.1 self-audit checklist in the PR.

## WP5 — Dictation handoff + hero flow (iM2)

**Repo:** `openwhisp-ios`. **Blocked by:** WP2 (decisions), WP3, WP4.

- `AppGroupHandoffStore` (atomic claim-rename consume, Data Protection class,
  expiry) + `DarwinHandoffNotifier` + `SharedStateStore` conformers.
- Floor flow: keyboard mic key → host dictation sheet (mechanism per WP2/R0b
  decision) → capture → publish → keyboard inserts on reappear
  (`TranscriptInsertPolicy`: spacing/caps/secure-field/expiry rules).
- Hero flow (if R0a passed): `StartDictationIntent: AudioRecordingIntent` +
  Control Center control + Action-button setup onboarding + Live Activity
  ("listening…" waveform, stop button → `StopDictationIntent`), publish path
  identical to floor.
- Keyboard live-insert path when frontmost (Darwin ping → consume → insert).

**Tests (gate):** handoff store semantics incl. racing-consumer test (tempdir);
InsertPolicy unit matrix (context × transcript × expiry × secure);
CaptureFlow additions for intent trigger; XCUITest for the app-switch round
trip on simulator where feasible; real-device checklist run for hero flow.
**Acceptance:** dictate into Safari/Notes via the keyboard end-to-end on a
real device using the floor flow; hero flow demoed if R0a passed.

## WP6 — P2P sync with the Mac (iM3)

**Repos:** both. **Blocked by:** WP0b, WP5 (or WP3 minimum). Two halves:

**WP6-mac (`openwhisp`):** `LANBridgeServer` — `NWListener` + Bonjour
advertise (`_openwhisp._tcp`) + TLS-PSK, feeding `BridgeRouter`; PSK pairing
store; "Pair iPhone…" settings pane (QR display, paired-device list, unpair);
sync verb handlers (manifest/pull/push against real stores); consent scope
`sync` via `AgentClientStore`. Reuse the wiring-review lesson: an E2E test
that drives a real TCP client against the running server.

**WP6-ios (`openwhisp-ios`):** `PairingService` (camera QR scan → Keychain
PSK), `BonjourPeerTransport: PeerTransport` returning a `BridgeSession`
conformer over `NWConnection`+TLS-PSK; `SyncEngine` (`plan()` pure merge per
ARCHITECTURE §6.5 policy + `run()`); sync UI (paired Mac card, "Sync now",
last-synced, conflict-free by construction); auto-sync on app foreground when
the peer is reachable.

**Tests (gate):** `plan()` merge matrix (every entity × newer/older/absent ×
both-changed); loopback TLS session test in-process; cross-repo integration:
phone-sim engine against WP6-mac handlers via TCP on localhost in CI (both
halves expose a test harness). **Acceptance:** edit vocabulary on the Mac →
sync → phone dictation applies it; history flows both ways; real-device +
real-Mac checklist run documented.

## WP7 — MCP client → Mac hub (iM4)

**Repo:** `openwhisp-ios` (+ small `openwhisp` follow-ups). **Blocked by:** WP6.

- Phone drives Mac tools over the paired `BridgeSession`: remote dictate
  (Mac captures, phone shows state), remote refine, remote history browse —
  a "Your Mac" tab in the host app.
- Voice-answer-to-agent: when a paired session is live and the Mac bridge
  surfaces an agent question, the phone can capture the spoken answer and
  return it (mobile analog of the agent-waiting overlay).
- Respect the bridge's consent + rate-limit envelope exactly as any agent.

**Tests (gate):** verb round-trips against a stub host; consent-denied and
rate-limited paths surfaced in UI. **Acceptance:** demo: agent on the Mac asks
a question, human answers by voice from the phone.

## WP8 — Polish & parity (iM5)

**Repo:** `openwhisp-ios`. **Blocked by:** WP5, WP6.

- Mode picker on the keyboard (long-press mic / mode row) + `SharedStateStore`
  persistence; `UITextContentType` mode *suggestions* (never silent auto-apply).
- Refine-last-dictation key (uses `RefineFlow` + the mac's refine provider via
  sync link, or on-device later; language guard via `RefineOutputGuard`).
- Voice commands during dictation (`VoiceEditCommand`) in the composer + handoff.
- ConfigPack import (Files/AirDrop) — Tier C; iPad layout pass; accessibility
  (VoiceOver on all keys, Dynamic Type in host app).
- Optional: CloudKit Tier B opt-in with the honest caveat copy — cut first if
  schedule pressure.

**Tests (gate):** each feature lands with MobileCore/KeyboardCore tests per
the working agreement. **Acceptance:** feature-parity table vs. mac app
documented; all gates green.

## WP9 — App Store release engineering

**Repo:** `openwhisp-ios`. **Blocked by:** WP5 minimum (WP8 ideally).

- Signing/provisioning (App Groups across three targets), TestFlight pipeline
  (GitHub Actions → `xcodebuild archive` → App Store Connect API key upload).
- Privacy nutrition label ("Data not collected"), review notes (4.4.1
  compliance narrative, Full Access explainer, open-source link), App Store
  page (screenshots incl. the privacy story), `openwhisp.app` site section.
- 4.4.1 pre-submission audit: typing with Full Access off, no network from
  the extension, explainer copy accuracy.
- TestFlight beta round → fix window → submit.

**Acceptance:** approved App Store listing.

---

## Dispatch notes for background agents

- Interfaces in ARCHITECTURE §6 are **binding names**; extend, don't rename,
  and update ARCHITECTURE.md in the same PR when reality forces a change.
- Every WP lands as one reviewable PR per repo, branch off `main`,
  `Co-Authored-By: Claude` trailer, tests included — **a WP without its test
  gate is not done** (see the wiring-review lesson: adversarially check that
  new wiring is actually reachable, and include a test that fails without it).
- Real-device steps cannot be automated: prepare the harness + a precise
  manual checklist, and hand off to the human.
- WP0/WP0b/WP6-mac PRs go to `openwhisp` and must keep its `swift test` and
  `./build.sh` green (WhisperKit default ON).
