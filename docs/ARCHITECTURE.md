# OpenWhisp iOS — Architecture

> Companion doc: [RESEARCH.md](RESEARCH.md) holds the fact-checked platform
> constraints ([C1]–[C11]) that this design is forced by. This doc turns that
> study into a buildable system: module boundaries, decisions, and the Swift
> interfaces each work package implements. [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)
> sequences the work.

---

## 1. System overview

Three product targets in one app, plus a shared local Swift package:

```
┌────────────────────────────── iPhone ──────────────────────────────┐
│                                                                     │
│  Keyboard Extension          Host App               Widgets Ext     │
│  (thin, memory-tight)        (the engine)           (Live Activity, │
│  ┌───────────────────┐       ┌──────────────────┐   Control Center) │
│  │ plain keyboard     │      │ AVAudioSession +  │  ┌────────────┐  │
│  │ (works w/o Full    │      │ AVAudioEngine     │  │ "listening"│  │
│  │  Access — 4.4.1)   │      │ WhisperKit (ANE)  │  │ Live Act.  │  │
│  │                    │      │ TranscriptCleaner │  │ CC record  │  │
│  │ mic key ─ teaches/ │      │ SilenceAutoStop   │  │ control ───┼──┼─▶ AudioRecordingIntent
│  │ hands off ─────────┼──┐   │ Sync + MCP client │  └────────────┘  │
│  │                    │  │   └───────┬──────────┘                   │
│  │ inserts text ◀─────┼──┼───────────┤ publishes PendingTranscript  │
│  │ (UITextDocumentProxy) │  App Group│ + Darwin notification        │
│  └───────────────────┘  │  container ▼                              │
│            ▲             └──▶ ~/AppGroup/handoff/…                  │
└────────────┼────────────────────────────────────────────────────────┘
             │ Full Access required for App Group read + network
             ▼
   ┌──────────────────┐   Bonjour + TLS (LAN only, paired via QR)
   │  Mac: OpenWhisp   │◀──────────────────────────────────────────
   │  (Agent Bridge =  │   sync.manifest / sync.pull / sync.push
   │  always-on MCP hub│   + existing dictate/refine/history verbs
   └──────────────────┘
```

Load-bearing constraints (all verified, see RESEARCH.md sources):

- **[C1]** Keyboard extensions have **no mic access**, even with Full Access →
  capture + Whisper run in the **host app**, keyboard only inserts.
- **[C9]/[C10]** A keyboard **cannot open its host app** (supported API), and a
  backgrounded app **cannot start recording** → the no-app-switch trigger is
  **`AudioRecordingIntent` via Action button / Control Center (iOS 18+)**, not
  the keyboard mic key.
- **[C2]** App Group + network in the keyboard are unlocked only by Full Access
  (`RequestsOpenAccess`).
- **[C8]** Guideline 4.4.1: the keyboard **must be a functional keyboard with
  Full Access off**; dictation is an enhancement, never a gate on typing.
- **[C7]** The phone cannot host an always-on server → Mac stays the MCP hub;
  phone is a client (+ optional foreground-only server).

---

## 2. Repository & target layout

```
openwhisp-ios/
├── project.yml                     # XcodeGen spec — .xcodeproj is generated, never committed
├── Packages/
│   └── OpenWhispMobileKit/         # local SwiftPM package — ALL logic lives here
│       ├── Package.swift           # depends on OpenWhispCore (github.com/initcore0/openwhisp)
│       ├── Sources/
│       │   ├── MobileCore/         # Foundation-only: handoff, sync engine, pairing state,
│       │   │                       #   insert policy, capture state machine — 100% swift-testable
│       │   ├── CaptureKit/         # host-side: AVAudioSession/AVAudioEngine adapters,
│       │   │                       #   WhisperKit engine wiring, App Intents glue
│       │   ├── SyncKit/            # Network.framework transports (NWListener/NWBrowser/TLS),
│       │   │                       #   conforms to MobileCore + BridgeKit seams
│       │   └── KeyboardCore/       # UIKit-free keyboard logic: layout model, key actions,
│       │                           #   autocap/spacing state — testable without the extension
│       └── Tests/
│           ├── MobileCoreTests/    # the `swift test` gate (mirrors macOS working agreement)
│           └── KeyboardCoreTests/
├── Apps/
│   ├── HostApp/                    # SwiftUI shell: onboarding, composer, settings, history,
│   │                               #   pairing UI, model manager — thin views over MobileKit
│   ├── KeyboardExtension/          # KeyboardViewController + key views; thin over KeyboardCore
│   └── WidgetsExtension/           # Live Activity ("listening…"), Control Center control,
│                                   #   Action-button App Intent surface
├── scripts/                        # bootstrap.sh (xcodegen), test.sh, benchmark.sh
├── fixtures/                       # WAV fixtures reused/adapted from the macOS repo
└── docs/
```

**Why a separate repo** (vs. a folder in `openwhisp`): different release
cadence (App Store vs. GitHub releases), different toolchain (xcodebuild +
simulators vs. raw `swiftc`), different CI. Shared logic flows through the
`OpenWhispCore` SwiftPM package — a real dependency edge instead of file
sharing, which forces the core to stay platform-clean.

---

## 3. What is reused from `OpenWhispCore` (and what it costs)

The macOS repo's package (`Package.swift`, target path `OpenWhisp/Services/`)
already contains the Foundation-only brain. Reused **as-is** once the upstream
prerequisite (WP0) lands:

| Reused type | Role on iOS |
|---|---|
| `SmartFormatter`, `TranscriptCleaner`, `PostProcessor(Chain)`, `MetaInstructionStripper` | The full post-processing pipeline, unchanged |
| `Vocabulary`, `VocabularySubstitutor` | Custom vocabulary + substitutions |
| `VoiceEditCommand`, `VoiceEditBuffer` | "scratch that", "new paragraph", … |
| `SilenceAutoStop` | VAD auto-stop for hands-free capture (critical for the Action-button flow, which has no stop button under the finger) |
| `TranscriptionHistory` types | Searchable history, same schema as Mac → syncable |
| `ConfigBundle` / `ConfigPack` (schema v2) | The sync + import/export payload |
| `AppProfile`, `ModeResolver`, `LanguageResolver` | Modes (degraded per-app semantics, §6.4) |
| `RefineFlow`, `InstructionChain`, `RefineOutputGuard`, `PrivacyStatus` | Refine state machine + language guard + privacy copy |
| `BridgeWire`, `BridgeRouter`, `AgentClientStore`, `AgentRateLimiter` | The entire sync/MCP wire protocol, routing, consent, and rate limiting (§7) |
| `WhisperKitBridge` (mapper), `WhisperKitModelCatalog` | Engine bridge + model staging catalog |
| `ParakeetCatalog`, `ParakeetLanguageGate`, `ParakeetLanguageHint`, `ParakeetDownloadState`, `StreamingRoutePolicy`, `AgentEouAutoStop` | Parakeet variant catalog, language routing/gating, download-state policy — the pure half of the primary engine (FluidAudio-linked engines are rebuilt for iOS in CaptureKit) |
| Protocol seams: `AudioCapture`, `TextOutput`, `StreamingTranscriptionEngine`, `FileTranscriptionEngine`, `SecretStore` | iOS supplies conformers (§6) |

**Upstream prerequisite (WP0, in the `openwhisp` repo):** the package today
declares only an *executable* product, targets `.macOS(.v13)` only, and keeps
most types `internal` (the mac app compiles them via a flat swiftc glob, not
`import OpenWhispCore`). WP0 adds:

1. `.library(name: "OpenWhispCore", …)` and `.library(name: "OpenWhispBridgeKit", …)` products.
2. `.iOS(.v18)` to `platforms`.
3. `public` on the types listed above (mechanical; `swift test` guards regressions).
4. `#if canImport(…)`/`#if os(macOS)` guards for the few mac-isms inside core
   files (e.g. `CoreAudio.AudioDeviceID` in `WhisperKitBridge` /
   `StreamingTranscriptionEngine.selectDevice` — become a platform-neutral
   `AudioDeviceHandle` typealias).
5. CI job that builds the two library products for an iOS destination.

Until versioned tags exist, `OpenWhispMobileKit` depends on
`.branch("main")`; at first TestFlight, switch to `.upToNextMinor(from:)` tags.

Not reused: `AgentBridgeServer` (Darwin sockets + macOS code-signing auth),
`TextInserter` (AX), `HotkeyMonitor`, `AudioRecorder` (CoreAudio device
enumeration), launch-at-login — all deliberately excluded from the package
already.

---

## 4. Decisions (ADR summary)

| # | Decision | Rationale / rejected alternative |
|---|---|---|
| **D1** | **Minimum deployment: iOS 18.0** | `AudioRecordingIntent` (the sanctioned background-capture trigger, [C11]) and Control Center controls are iOS 18+. Shipping iOS 17 support would fork the hero UX for a shrinking cohort. iPadOS 18 same bar. |
| **D2** | **XcodeGen; `.xcodeproj` is generated and git-ignored** | Extensions + entitlements require an Xcode project (raw swiftc can't ship a keyboard). XcodeGen keeps the repo diff-reviewable and preserves the parent project's no-`.xcodeproj` hackability ethos. Tuist rejected as heavier than needed. |
| **D3** | **Share code via SwiftPM dependency on `initcore0/openwhisp`** | Real dependency edge; no submodule drift, no copied files. Requires WP0 (library product + iOS platform + visibility). |
| **D4** | **Hand-rolled minimal keyboard (QWERTY + symbols), no third-party keyboard framework** | The keyboard extension lives under a ~30–60 MB jetsam ceiling; KeyboardKit adds weight and a dependency we don't control in the most review-scrutinized target. Our keyboard's job is dictation-first; v1 typing = layout, shift/autocap, backspace repeat, symbols page, globe, return. No autocorrect in v1 (honest scope; competitors' dictation keyboards do the same). Revisit only if App Store feedback demands it. |
| **D5** | **Engine strategy (updated 2026-07-11, Parakeet merged upstream in PR #163): Parakeet via FluidAudio is the PRIMARY engine — `nemotron-multilingual-1120ms` streaming (~40 languages, auto-detect, punctuation) as the multilingual default, `parakeet-unified-320ms` for low-latency English, TDT v3 for file/batch jobs. WhisperKit (`tiny`/`base`/`small`) is the SECONDARY engine for the ~100-language long tail. Apple `SFSpeechRecognizer`/`SpeechAnalyzer` ships only as a benchmark BASELINE inside the Engine Lab — never a production path.** | Goal #1 is beating Apple's built-in recognition, especially multilingual; Nemotron streaming + Whisper long-tail does that while staying fully on-device. All engines sit behind the upstream `StreamingTranscriptionEngine`/`FileTranscriptionEngine` seams, and the Engine Lab (§WP3) measures us against the Apple baseline on the same audio so the claim is provable, not vibes. FluidAudio is Apache-2.0 and iOS-compatible; upstream core already contains the pure Parakeet types (`ParakeetCatalog`, `ParakeetLanguageGate/Hint`, `ParakeetDownloadState`). |
| **D6** | **Sync default = Tier A P2P (Bonjour + TLS-PSK, QR-paired); Tier C file export free; Tier B CloudKit = explicitly-labeled later opt-in** | "Nothing leaves your devices" is the headline and is only true for Tier A. CloudKit ships with the honest caveat or not at all. |
| **D7** | **Transcripts move ONLY through the App Group container** | Never through URL schemes, pasteboard, or notifications (all observable by other processes). Handoff files are encrypted-at-rest by iOS Data Protection (`.completeUntilFirstUserAuthentication`) and expire in 120 s. |
| **D8** | **The keyboard mic key = state-aware affordance, not a recorder** | Full Access off → explainer sheet. No pending transcript → teaches/launches the capture path chosen in WP2 (Action button setup, or manual app-switch flow). Pending transcript exists → inserts it. The key never pretends to record. [C1, C9] |
| **D9** | **Mac stays the always-on MCP hub; phone is MCP client + optional foreground-only server** | iOS backgrounding kills server sockets in ~30 s [C7]. Phone drives Mac tools over the paired link; "lend the phone's mic to an agent" works only with the app foregrounded. |
| **D10** | **Bundle IDs**: app `app.openwhisp.ios`, keyboard `app.openwhisp.ios.keyboard`, widgets `app.openwhisp.ios.widgets`; App Group `group.app.openwhisp.ios`; Bonjour service `_openwhisp._tcp` (same as Mac). | Matches the openwhisp.app domain. |

---

## 5. The dictation flows (product truth, ranked)

1. **Hero — no app switch (iOS 18+):** user triggers the **Action button /
   Control Center control** → `AudioRecordingIntent` starts host capture
   without foregrounding [C11] → Live Activity/Dynamic Island shows
   "listening…" → `SilenceAutoStop` ends capture → host transcribes, runs
   `TranscriptCleaner`, publishes a `PendingTranscript` to the App Group +
   Darwin notification → keyboard (if frontmost) inserts at the caret
   instantly; otherwise inserts on next keyboard appearance.
   *Gated on the WP2/R0a real-device spike; known reports of background-start
   failures from some surfaces.*
2. **Floor — quick app switch (always works, App-Store-safe):** keyboard mic
   key opens the host's compact **dictation sheet** (mechanism decided by
   R0b: manual switch vs. the unsupported-but-common openURL hack — measure,
   then decide with eyes open) → user speaks → auto-stop → user returns via
   the back-breadcrumb → keyboard inserts the pending transcript on
   `viewWillAppear`.
3. **In-app composer:** dictate long-form inside the host app, then share/copy.
   Trivial (normal mic access); ships first (WP3) and is the benchmark harness.

Insertion is idempotent and expiring: a `PendingTranscript` is consumed
atomically exactly once, and never inserted after `expiresAt` (120 s) so a
stale dictation can't land into tomorrow's password field.

**Status (WP5).** The **floor flow is implemented**: the host registers the
`openwhisp://` URL scheme, `openwhisp://dictate` (parsed by the tested
`DeepLink` router) presents the compact **dictation sheet** — a
`CaptureCoordinator` built on the live App Group `HandoffEnvironment`, trigger
`.keyboardHandoff`, `SilenceAutoStop` armed — which publishes the cleaned
transcript, fires the `DarwinHandoffNotifier`, and mirrors the coarse capture
state (`capturing`→`transcribing`→`idle`) through `FileSharedStateStore` for the
keyboard's mic key. The composer's "Dictate for another app" button takes the
same path. The **hero surfaces are implemented**: `StartDictationIntent`
(`AudioRecordingIntent`) / `StopDictationIntent`, the "Listening…" Live Activity
+ Dynamic Island (Stop button, brief "Inserted ✓"), and the Control Center
control, plus an Action-button setup walkthrough in Settings. **Background
capture-start from the intent is pending the R0a real-device pass** (the
simulator cannot prove it): the intent path degrades to opening the app
(`openAppWhenRun` fallback) if in-process capture can't start, and the exact
per-surface behavior is the Tier-4 R0a matrix in [TESTING.md](TESTING.md).

---

## 6. Interfaces

Everything below lives in `OpenWhispMobileKit`. `MobileCore` and
`KeyboardCore` are Foundation-only (the `swift test` surface); `CaptureKit`
and `SyncKit` hold the OS-bound conformers. Names are binding for WP
implementers; signatures may grow but not change meaning.

### 6.1 Handoff (MobileCore) — the load-bearing seam

```swift
/// A finished, cleaned transcript the host publishes for the keyboard to insert.
public struct PendingTranscript: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String            // ALREADY post-processed (TranscriptCleaner ran in host)
    public let createdAt: Date
    public let expiresAt: Date         // createdAt + 120s; never insert past this
    public let source: Source
    public enum Source: String, Codable, Sendable { case appIntent, appSwitch, inApp }
}

/// Atomic single-consumer mailbox in the App Group container.
/// Concrete: `AppGroupHandoffStore` (file-based, O_EXCL claim rename for atomic consume,
/// Data Protection `.completeUntilFirstUserAuthentication`).
/// Test double: `InMemoryHandoffStore`.
public protocol DictationHandoffStore: Sendable {
    func publish(_ transcript: PendingTranscript) throws
    func peek() throws -> PendingTranscript?
    /// Atomically takes the transcript iff `id` matches and it is unexpired. nil = already consumed/expired.
    func consume(id: UUID, now: Date) throws -> PendingTranscript?
    func discardAll() throws
}

/// Cross-process "new transcript" ping. Concrete: `DarwinHandoffNotifier`
/// (CFNotificationCenterGetDarwinNotifyCenter, name "app.openwhisp.handoff.published").
/// Carries NO payload — the keyboard reads the store. Fallback path is the
/// store read on keyboard `viewWillAppear` (Darwin notifications are best-effort).
public protocol HandoffNotifier: AnyObject {
    func notifyPublished()
    var onPublished: (() -> Void)? { get set }
}

/// Host ⇄ keyboard shared flags (also App Group; small JSON, not UserDefaults —
/// keep one audited file format). Includes: capture state for the mic key,
/// selected mode, keyboard settings snapshot.
public protocol SharedStateStore: Sendable {
    func readCaptureState() -> HandoffCaptureState      // idle | capturing | transcribing
    func writeCaptureState(_ s: HandoffCaptureState)
    func readKeyboardConfig() -> KeyboardConfig          // mode, haptics, autocap…
    func writeKeyboardConfig(_ c: KeyboardConfig)
}
```

### 6.2 Capture orchestration (state machine in MobileCore, I/O in CaptureKit)

```swift
public enum CaptureTrigger: Sendable { case inApp, appIntent, keyboardHandoff }

public enum CaptureState: Equatable, Sendable {
    case idle
    case preparing                       // session activation, model warm
    case listening(level: Float)         // drives Live Activity + waveform
    case transcribing
    case published(PendingTranscript.ID) // handed off
    case failed(CaptureFailure)          // micDenied, sessionInterrupted, engineError, jetsamRisk
}

/// Pure state machine (MobileCore, tested exhaustively): events in, effects out.
/// Mirrors the RefineFlow pattern from the mac app — AppState-style shells stay dumb.
public struct CaptureFlow {
    public enum Event { case trigger(CaptureTrigger), audioReady, level(Float),
                        silenceStopped, manualStop, cancel, engineFinal(String),
                        cleaned(text: String), engineError(String), interrupted }
    // Contract: engineFinal emits ONLY .clean(raw:); the driver runs
    // TranscriptCleaner and feeds the result back as .cleaned, the sole path to
    // a .publish effect — raw engine text can never reach publish. didPublish(id:)
    // returns [.updateActivity(.published(id)), .endActivity] so activity
    // teardown is part of the tested contract, not a driver convention.
    // stopEngine(cancel:) is part of the effect vocabulary; engine teardown is
    // never implicit — the driver stops the engine ONLY on an explicit stopEngine
    // effect (cancel:false lets a decode finish, cancel:true discards it).
    public enum Effect { case startAudio, stopAudio, startEngine(language: String),
                         stopEngine(cancel: Bool),
                         clean(raw: String), publish(text: String, source: PendingTranscript.Source),
                         updateActivity(CaptureState), endActivity, abort(CaptureFailure) }
    public private(set) var state: CaptureState
    public mutating func handle(_ event: Event) -> [Effect]
}

/// The host-side driver (CaptureKit, @MainActor): owns AVAudioSession config
/// (.playAndRecord, .measurement, bluetooth), the iOS AudioCapture conformer,
/// the StreamingTranscriptionEngine, SilenceAutoStop, TranscriptCleaner, and
/// executes CaptureFlow effects. Reuses upstream protocol seams:
///   - `IOSAudioCapture: AudioCapture`      (AVAudioEngine tap; VAD/RMS math from core)
///   - `WhisperKitMobileEngine: StreamingTranscriptionEngine`
public protocol CaptureCoordinating: AnyObject {
    var state: CaptureState { get }
    var onStateChange: ((CaptureState) -> Void)? { get set }
    func begin(trigger: CaptureTrigger) async
    func stop() async                    // user stop; still transcribes
    func cancel() async                  // discard everything
}

/// App Intents surface (WidgetsExtension + host): the iOS-18 sanctioned trigger.
/// `StartDictationIntent: AudioRecordingIntent` → CaptureCoordinating.begin(.appIntent)
/// + starts the Live Activity. `StopDictationIntent` from the Live Activity button.
/// Shape verified in WP2 (R0a) before anything builds on it.
```

### 6.3 Model provisioning (CaptureKit + MobileCore catalog reuse)

```swift
/// Downloads + stages WhisperKit CoreML models into the HOST app container
/// (never the App Group — the keyboard must not pay for models it can't run).
/// Reuses upstream `WhisperKitModelCatalog` for identity/staging checks.
public protocol ModelProvisioning: AnyObject {
    var staged: [StagedModel] { get }
    func download(_ model: ModelID, progress: @escaping (Double) -> Void) async throws
    func delete(_ model: ModelID) throws
    func recommendedDefault(for device: DeviceClass) -> ModelID   // tiny/base/small by RAM
}
```

Download is the **only** non-LAN network call in the entire product (Hugging
Face model CDN, or bundled `tiny` for offline-first onboarding — WP3 decides
after size/review checks). It is user-initiated, shown with progress, and
listed in the privacy notes.

### 6.4 Keyboard (KeyboardCore = logic, KeyboardExtension = thin UIKit shell)

```swift
/// Everything the keyboard does to text, abstracted off UITextDocumentProxy
/// so KeyboardCore is testable. The extension provides `ProxyTextSink`.
public protocol KeyboardTextSink: AnyObject {
    func insert(_ text: String)
    func deleteBackward(_ count: Int)
    var contextBeforeCaret: String? { get }   // documentContextBeforeInput
    var returnKeyLabel: ReturnKeyLabel { get }
    var isSecureField: Bool { get }           // UITextContentType/secureTextEntry heuristic
    var hasFullAccess: Bool { get }
}

/// Pure insert policy: given caret context + a transcript, decide leading/trailing
/// space and capitalization (delegating sentence logic to upstream SmartFormatter
/// conventions). Also: NEVER insert into a secure field (mirror the mac
/// SecureFieldPolicy contract — on iOS the signal is isSecureTextEntry).
public struct TranscriptInsertPolicy {
    public func rendered(_ t: PendingTranscript, context: String?) -> String
    public func permitted(_ t: PendingTranscript, sink: KeyboardTextSink, now: Date) -> Bool
}

/// Pure keyboard model: layout pages (letters/symbols/numbers), shift state
/// (off/on/capsLock), autocap after sentence breaks, backspace repeat cadence,
/// key action resolution. The UIKit layer is dumb rendering + touch → KeyAction.
public struct KeyboardLayoutModel { /* pages, keys, shift/autocap state machine */ }
public enum KeyAction { case character(String), backspace, shift, globe,
                        returnKey, space, page(LayoutPage), mic, refineLast }

/// Mic-key behavior (D8) — pure resolver, exhaustively tested:
public enum MicKeyResolver {
    public static func resolve(fullAccess: Bool,
                               captureState: HandoffCaptureState,
                               pending: PendingTranscript?,
                               now: Date) -> MicKeyBehavior
    // → .insertPending(id:) | .showCaptureUX | .explainFullAccess | .showCapturing
}
```

Per-app modes degrade on iOS (a keyboard cannot identify its host app): the
mode is user-picked from the keyboard (long-press mic key or a mode row) and
persisted via `SharedStateStore`; `UITextContentType`/return-key heuristics
may auto-suggest a mode later — never auto-apply silently.

### 6.5 Pairing & sync (SyncKit transports, MobileCore engine)

The wire **is** the Agent Bridge: NDJSON JSON-RPC (`BridgeWire`,
`protocolVersion` bump to add sync verbs), routed by `BridgeRouter`, consented
via `AgentClientStore` — over TLS/TCP instead of a UNIX socket.

```swift
/// A paired device (Mac). Persisted in Keychain via upstream `SecretStore` conformer.
public struct PeerIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String        // "Max's MacBook Pro"
    public let pskFingerprint: String     // for the pairing-confirm UI
    public let lastSeen: Date?
}

/// Out-of-band pairing: Mac shows a QR (openwhisp menu → "Pair iPhone…"),
/// phone scans. Payload = { peerID, displayName, TLS-PSK (32B), service instance }.
/// TLS 1.3 PSK via NWProtocolTLS (sec_protocol_options_add_pre_shared_key) —
/// mutual auth without a CA, nothing on the wire before the handshake.
public protocol PairingService: AnyObject {
    func completePairing(scannedQR: Data) async throws -> PeerIdentity
    func unpair(_ peer: PeerIdentity.ID) throws
    var pairedPeers: [PeerIdentity] { get }
}

/// Bonjour discovery + TLS connection. The returned session conforms to the
/// UPSTREAM BridgeKit `BridgeSession` protocol (handshake/call), so
/// PersistentBridge + MCP plumbing work unchanged over the LAN.
public protocol PeerTransport: AnyObject {
    func discover(onFound: @escaping (DiscoveredPeer) -> Void) -> DiscoveryToken
    func connect(to peer: PeerIdentity) async throws -> any BridgeSession
}

/// Sync = foreground, on-demand/on-launch (iOS suspension makes daemons impossible
/// — and that's fine for config/history). Payload = upstream ConfigBundle (v2)
/// + a history delta. New bridge verbs (added upstream in WP0b, wire v1.1):
///   sync.manifest → { schemaVersion, vocabHash, profilesHash, packsHash, historyHead, updatedAt map }
///   sync.pull     → full or delta ConfigBundle + history entries since a cursor
///   sync.push     → same shape, phone→Mac
public protocol SyncEngine {
    func plan(local: SyncManifest, remote: SyncManifest) -> SyncPlan   // pure, fully tested
    func run(with session: any BridgeSession) async throws -> SyncReport
}
```

**Merge policy (v1, deliberately boring):** vocabulary = union by
`Substitution.id`, newer `updatedAt` wins per entry; history = append-only
union by entry `id`; profiles/modes/settings = last-writer-wins per object by
`updatedAt`; packs = content-hash identity. No CRDTs until real conflict pain
exists. (Requires `updatedAt` stamps on vocab entries/profiles — small
upstream schema addition, WP0b, schema v3 with v2 decode fallback.)

### 6.6 MCP (SyncKit + upstream BridgeKit)

**Status: WP7 SHIPPED.** The phone drives the Mac's tools over the paired link.

- **Phone → Mac (WP7 — done):** `RemoteMacClient` (SyncKit) drives the Mac's
  existing `status` / `dictate` / `dictate.stop` / `refine` / `history.list`
  verbs over the SAME `BridgeSession` sync uses — a handshaked TLS-PSK
  `NWConnection` from `BonjourPeerTransport.connect(to:psk:clientName:)`, the
  identical path `SyncCoordinator` takes. **No new transport, no MCP SDK, no
  server-side work:** the Mac's `LANBridgeServer` already routes phone traffic
  through the same per-peer `AgentScope` consent (dictate/history/refine/sync)
  and `AgentRateLimiter`. The phone is "one more agent client." A denied scope /
  throttle / busy mic / stale LLM comes back as a `BridgeWire` domain error
  (`consentDenied`, `rateLimited`, `busy`, `timeout`, `micPermissionNeeded`,
  `secureField`, `llmUnavailable`, `cloudRefineDisabled`, `historyDisabled`),
  which the pure `RemoteMacError.from(...)` maps to an explicit UI state — never
  a silent failure.
- **Voice-answer-to-agent — NO new verb:** an agent question IS just
  `dictate(prompt: "<question>")`. The Mac shows its agent-question overlay (+
  optional TTS) and returns the human's spoken answer in `DictateResult.text`.
  So "the Mac asks, I answer by voice from the phone" = call `dictate` with a
  prompt and display the returned text. The Settings → Your Mac drive surface
  exposes this as "Answer a question by voice."
- **Layering.** The OS-bound `RemoteMacClient` stays thin; every decision — wire
  error → `RemoteMacError`, `HistoryEntryDTO` → `RemoteHistoryItem`,
  dictate-state fold — lives in the pure, `swift test`-covered `SyncCore` layer.
- **Foreground-only** (like sync): each drive call opens a fresh TLS-PSK session,
  runs off-main, and closes it. iOS tears down the socket within ~30s of
  backgrounding, so the drive controls are meant to be used while the app is
  open. `RemoteMacCoordinator` fails-silent-to-journal exactly as sync does.
- **Foreground-only phone MCP server (post-v1):** Streamable HTTP via the MCP
  Swift SDK while the app is open — "lend the phone's mic to an agent" mode.

### 6.7 Mac-side counterpart (lives in the `openwhisp` repo)

A new `LANBridgeServer`: `NWListener` + Bonjour advertise + TLS-PSK, feeding
accepted connections into the existing `BridgeRouter`/`AgentBridgeHost`
pipeline. Auth swaps macOS code-signing peer checks for the pairing PSK
(there is no cross-device code-signing identity). Gated by a new
"Pair iPhone…" settings surface that shows the QR and lists paired devices.
Sync verbs handled next to the existing verb handlers. This is WP6-mac.

---

## 7. Security & privacy model

| Surface | Posture |
|---|---|
| Audio & transcripts | Never leave the device except: (a) opt-in P2P sync to the user's paired Mac over TLS-PSK on the LAN; (b) nothing else. No analytics, no crash SDKs with payloads, no third-party SDKs at all. |
| Handoff files | App Group container, iOS Data Protection `.completeUntilFirstUserAuthentication`, 120 s expiry, atomic single consume (D7). |
| Secure fields | Keyboard refuses insertion when `isSecureField` (mirrors mac `SecureFieldPolicy`). The extension also cannot dictate (no mic) — so no transcript can originate in a password context. |
| Pairing | QR out-of-band (camera, no network), 32-byte PSK in Keychain (`SecretStore` conformer), TLS 1.3 mutual PSK; unpair = key destruction. |
| LAN exposure | Mac listener only runs when pairing is configured; per-scope consent (`AgentScope.dictate/history/refine`) + `AgentRateLimiter` apply to the phone exactly as to any agent. |
| Full Access story | Plain-language explainer screen: what Full Access unlocks (App Group read + LAN sync), what we never do (no logging, no network besides your Mac, open source). Keyboard fully functional without it [C8]. |
| Privacy nutrition label | "Data not collected." Model download disclosed as user-initiated. |

Info.plist inventory: `NSMicrophoneUsageDescription` (host),
`NSLocalNetworkUsageDescription` + `NSBonjourServices: _openwhisp._tcp` (host),
`NSCameraUsageDescription` (QR pairing), `RequestsOpenAccess` (keyboard),
`NSSupportsLiveActivities` (widgets), and `NSSpeechRecognitionUsageDescription`
(host). **The speech-recognition usage string exists solely for the developer
Engine Lab** (Settings → Developer → Engine Lab), which runs Apple's
`SFSpeechRecognizer` **as a benchmark baseline only** — forced on-device
(`requiresOnDeviceRecognition = true`), never as a production transcription path
(D5) and never sending dictated text to Apple. No *production* code path touches
`SFSpeechRecognizer`; the `AppleSpeechBaselineEngine` is reachable only from the
Lab, behind an explicit authorization request. No other speech entitlement is
added. The Lab's benchmark WAV fixtures ship in **Debug builds only** (a
Release-config post-build step strips them from the product) so the shipped app
carries no fixture payload — see [ENGINE_LAB.md](ENGINE_LAB.md).

---

## 8. Testing strategy (inherited working agreement)

Same law as the mac repo: **every feature gets an automated test; `swift test`
on `OpenWhispMobileKit` is the always-green gate (~seconds, no simulator).**

1. **`swift test` (MobileCore/KeyboardCore)** — CaptureFlow state machine
   (every event × state), MicKeyResolver (full truth table),
   TranscriptInsertPolicy (spacing/caps/secure-field/expiry),
   AppGroupHandoffStore semantics via `InMemoryHandoffStore` + a tempdir
   file-store test (atomic consume under racing readers), SyncEngine `plan()`
   (manifest × manifest → plan, all merge rules), pairing payload
   encode/decode, layout/shift/autocap model. Fixture WAVs drive
   cleaner-pipeline tests exactly like the mac `FeatureMatrixE2ETests`.
2. **Loopback sync test** — `SyncEngine` end-to-end over an in-process pair of
   TLS `NWConnection`s (or an in-memory `BridgeSession`), against a stub Mac
   handler built from upstream `BridgeRouter` — proves the wire without a Mac.
3. **Simulator XCUITest (small, CI)** — keyboard appears, types, globe works,
   Full-Access-off path shows explainer; host composer smoke.
4. **Real-device checklists (manual/nightly, not CI-blocking)** — R0a/R0b/R0c
   spike scripts (WP2), WhisperKit memory/latency/thermals benchmark matrix
   (WP3), cross-device sync against a real Mac (WP6).

CI: GitHub Actions macOS runner — `swift test` on the package, `xcodegen` +
`xcodebuild build` for all three targets, XCUITest smoke on one simulator.

---

## 9. Known risks (ranked) and their gates

| Risk | Gate |
|---|---|
| **R0a** `AudioRecordingIntent` background capture-start fails on device from Action button/Control Center | WP2 spike **before** any hero-UX work; failure ⇒ hero degrades to app-switch flow, marketing copy adjusts. |
| **R0b** keyboard→host trigger UX (manual switch vs. unsupported openURL hack) | WP2 measures both; decision recorded in this doc before WP5. |
| **R0c** return-trip insert reliability (Darwin + viewWillAppear across app-switch) | WP2; mitigation already designed (store-read fallback, expiry). |
| WhisperKit peak RAM on low-RAM iPhones (host jetsam during transcription) | WP3 benchmark matrix (tiny/base/small × iPhone 12/SE/15/16) before defaulting a model. |
| App review: Full Access scrutiny | 4.4.1-by-construction (WP4 ships a working keyboard with Full Access off) + review notes + open source. |
| Upstream visibility churn (WP0 makes ~30 types public) | Mechanical PR, `swift test` green upstream; branch-pin until tagged. |
