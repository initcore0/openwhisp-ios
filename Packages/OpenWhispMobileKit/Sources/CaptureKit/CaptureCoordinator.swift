import Foundation
import MobileCore
import OpenWhispCore

/// The host-side capture driver (ARCHITECTURE §6.2, WP3). `@MainActor`, conforms to
/// `MobileCore.CaptureCoordinating`, and drives the pure `CaptureFlow` state
/// machine: it feeds events in and executes the effects the machine emits —
/// LITERALLY, one effect at a time. That literalness is the whole point of the
/// design and the §6.2 contract:
///
///   - Raw engine text is fed as `.engineFinal(raw)`, which the machine turns into
///     a `.clean(raw:)` effect. Only when the driver runs `TranscriptCleaner` and
///     feeds the result back as `.cleaned(text)` does the machine emit `.publish`.
///     So a `.publish` effect can ONLY ever carry cleaned text, and the driver
///     publishes exactly the text the `.publish` effect carries — never the raw
///     transcript, never a re-derived string.
///   - `cancel`/`interrupted` paths never reach `.publish`, so a discarded or
///     interrupted capture publishes nothing.
///
/// Wiring:
///   - `StreamingTranscriptionEngine` (Parakeet primary / WhisperKit secondary):
///     owns the mic tap. Its `onLevelChanged` → `.level`; `onFinal` → `.engineFinal`;
///     `onError` → `.engineError`.
///   - `SilenceAutoStop` (OpenWhispCore): fed the absolute-curve VAD level from each
///     `.level`; when it fires, the driver feeds `.silenceStopped` (hands-free stop,
///     critical for the Action-button flow with no stop button under the finger).
///   - `TranscriptCleaner` (OpenWhispCore, with `Vocabulary`): runs on the
///     `.clean(raw:)` effect; result is fed back as `.cleaned`.
///   - `DictationHandoffStore`: the `.publish` effect writes the `PendingTranscript`;
///     the resulting id goes back through `flow.didPublish(id:)`.
public final class CaptureCoordinator: CaptureCoordinating, @unchecked Sendable {

    // MARK: CaptureCoordinating

    public private(set) var state: CaptureState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((CaptureState) -> Void)?

    /// Optional live-partial sink for the in-app composer / live preview. Fed the
    /// engine's `onPartial` verbatim — partials are NOT part of the publish
    /// contract (only the cleaned final is), so they bypass the state machine.
    public var onPartial: ((String) -> Void)?

    // MARK: Collaborators

    private let engine: StreamingTranscriptionEngine
    private let session: AudioSessionControlling
    private let handoffStore: DictationHandoffStore
    private let notifier: HandoffNotifier?
    private let cleanerConfig: TranscriptCleaner.Config
    private let language: String
    private let now: () -> Date
    private let monotonic: () -> TimeInterval

    private var flow: CaptureFlow
    private var silence: SilenceAutoStop
    private let silenceConfig: SilenceAutoStop.Config

    public init(
        engine: StreamingTranscriptionEngine,
        session: AudioSessionControlling,
        handoffStore: DictationHandoffStore,
        notifier: HandoffNotifier? = nil,
        cleanerConfig: TranscriptCleaner.Config,
        language: String = "en",
        silenceConfig: SilenceAutoStop.Config = .default,
        now: @escaping () -> Date = Date.init,
        monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.engine = engine
        self.session = session
        self.handoffStore = handoffStore
        self.notifier = notifier
        self.cleanerConfig = cleanerConfig
        self.language = language
        self.silenceConfig = silenceConfig
        self.now = now
        self.monotonic = monotonic
        self.flow = CaptureFlow(state: .idle, language: language)
        self.silence = SilenceAutoStop(config: silenceConfig)

        wireEngine()
    }

    // MARK: - Public control (CaptureCoordinating)

    public func begin(trigger: CaptureTrigger) async {
        await MainActor.run { self.dispatch(.trigger(trigger)) }
    }

    public func stop() async {
        await MainActor.run { self.dispatch(.manualStop) }
    }

    public func cancel() async {
        await MainActor.run { self.dispatch(.cancel) }
    }

    // MARK: - Engine callbacks → events

    private func wireEngine() {
        engine.onLevelChanged = { [weak self] _, vad in
            guard let self else { return }
            Task { @MainActor in self.handleLevel(vad) }
        }
        engine.onPartial = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in self.onPartial?(text) }
        }
        engine.onFinal = { [weak self] raw in
            guard let self else { return }
            Task { @MainActor in self.dispatch(.engineFinal(raw)) }
        }
        engine.onError = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in self.dispatch(.engineError(message)) }
        }
    }

    /// A live VAD level. Drive `SilenceAutoStop`; on fire, request a silence stop.
    /// Also forward the level as an event so the Live Activity updates.
    @MainActor
    private func handleLevel(_ vad: Float) {
        dispatch(.level(vad))
        // Only arm/fire while actually listening.
        if case .listening = state {
            let fired = silence.ingest(level: vad, now: monotonic())
            if fired {
                dispatch(.silenceStopped)
            }
        }
    }

    // MARK: - The literal effect executor

    /// Pending follow-up events an effect asked to feed back in (e.g. `.startAudio`
    /// producing `.audioReady`, `.clean` producing `.cleaned`). Draining them AFTER
    /// the current event's whole effect batch finishes preserves the machine's own
    /// effect ordering — a follow-up event must not run mid-batch, or a trailing
    /// `.updateActivity(...)` in the same batch would clobber the state the
    /// follow-up just advanced (the ".preparing overwrites .listening" bug).
    private var pendingEvents: [CaptureFlow.Event] = []
    private var draining = false

    /// Feed an event into the flow. Re-entrant calls (from inside `execute`) just
    /// enqueue; the top-level call drains the whole queue in FIFO order, running
    /// each event's effects to completion before the next event starts.
    @MainActor
    private func dispatch(_ event: CaptureFlow.Event) {
        pendingEvents.append(event)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pendingEvents.isEmpty {
            let next = pendingEvents.removeFirst()
            // A `.stopAudio` effect is emitted both by a normal stop (still
            // transcribes) and by a cancel/interrupt (discard). The effect alone
            // can't tell them apart, but the EVENT can: on cancel/interrupt we cancel
            // the engine (drop its final); on manual/silence stop we let it finish.
            currentEventDiscards = (next == .cancel || next == .interrupted)
            for effect in flow.handle(next) {
                execute(effect)
            }
        }
    }

    /// True while processing a `.cancel`/`.interrupted` event — makes `.stopAudio`
    /// cancel the engine (discard its final) rather than let it transcribe.
    private var currentEventDiscards = false

    @MainActor
    private func execute(_ effect: CaptureFlow.Effect) {
        switch effect {
        case .startAudio:
            // Activate the audio session, then signal readiness. A failure aborts
            // the flow via `.interrupted` (session unavailable ≈ interruption).
            do {
                try session.activate()
                // Fresh capture → reset the silence detector for this utterance.
                silence = SilenceAutoStop(config: silenceConfig)
                // Audio is live; advance the machine (which will emit .startEngine).
                dispatch(.audioReady)
            } catch {
                dispatch(.interrupted)
            }

        case .stopAudio:
            // End capture. On a normal stop the engine still transcribes (→ onFinal);
            // on a cancel/interrupt it discards (no final reaches the — now idle —
            // machine anyway, but cancelling saves a wasted decode).
            engine.stop(cancel: currentEventDiscards)

        case .startEngine(let language):
            do {
                try engine.start(language: language)
            } catch {
                dispatch(.engineError(error.localizedDescription))
            }

        case .clean(let raw):
            // Run TranscriptCleaner (with Vocabulary) — the ONLY producer of the
            // text that can reach a publish. Feed the cleaned result straight back.
            let cleaner = TranscriptCleaner(config: cleanerConfig)
            let cleaned = cleaner.clean(raw, isFinalTranscript: true)
            dispatch(.cleaned(text: cleaned))

        case .publish(let text, let source):
            // Publish EXACTLY the text the effect carries — this is cleaned text by
            // construction (it came from a `.cleaned` event). Never the raw
            // transcript. An empty cleaned string (ignorable utterance) is NOT
            // published — nothing to insert; cancel the flow (which tears down the
            // activity) and release the session.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                for e in flow.handle(.cancel) { execute(e) }
                session.deactivate()
                return
            }
            let created = now()
            let transcript = PendingTranscript(
                id: UUID(),
                text: text,
                createdAt: created,
                source: source
            )
            do {
                try handoffStore.publish(transcript)
                notifier?.notifyPublished()
                // Record the publish so the machine's state reflects reality, and
                // run the returned activity-teardown effects (updateActivity(.published)
                // then endActivity). `endActivity` releases the session, so we don't
                // deactivate again here.
                let post = flow.didPublish(id: transcript.id)
                for e in post { execute(e) }
            } catch {
                dispatch(.engineError("Handoff publish failed: \(error.localizedDescription)"))
            }

        case .updateActivity(let newState):
            state = newState

        case .endActivity:
            // The machine has returned to idle/published; make sure the audio
            // session is released and the coarse state settles. Only force idle
            // when we're not already showing a terminal published state.
            if case .published = state {
                // keep the published state visible; nothing to do
            } else {
                state = .idle
            }
            session.deactivate()

        case .abort(let failure):
            engine.stop(cancel: true)
            state = .failed(failure)
            session.deactivate()
        }
    }
}

/// The audio-session lever the coordinator needs, abstracted so `CaptureKitTests`
/// can drive the full flow without AVAudioSession (no simulator/mic). The real iOS
/// conformer (`IOSAudioSessionController`, in AudioSessionBridge.swift) wraps
/// `AVAudioSession`; this protocol is platform-neutral so the coordinator and its
/// tests compile on the macOS `swift test` host.
public protocol AudioSessionControlling: AnyObject {
    /// Activate the `.playAndRecord`/`.measurement` session. Throws if unavailable.
    func activate() throws
    /// Release the session (notifying others).
    func deactivate()
}
