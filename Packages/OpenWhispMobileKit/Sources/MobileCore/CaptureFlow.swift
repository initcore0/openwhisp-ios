import Foundation

// MARK: - Capture orchestration (ARCHITECTURE §6.2)
//
// The state machine lives here in MobileCore and is tested exhaustively; all the
// actual I/O (AVAudioSession, the engine, SilenceAutoStop, TranscriptCleaner)
// lives in CaptureKit and merely *executes* the effects this machine emits. This
// mirrors the `RefineFlow` pattern from the mac app: the shell stays dumb.

/// What kicked off a capture.
public enum CaptureTrigger: Sendable, Equatable {
    case inApp
    case appIntent
    case keyboardHandoff
}

/// The full capture lifecycle as seen by the host (richer than the
/// cross-process `HandoffCaptureState`).
public enum CaptureState: Equatable, Sendable {
    case idle
    /// Session activation, model warm-up.
    case preparing
    /// Actively recording; `level` drives the Live Activity + waveform.
    case listening(level: Float)
    case transcribing
    /// Handed off — carries the id of the published transcript.
    case published(PendingTranscript.ID)
    case failed(CaptureFailure)
}

/// Terminal failure reasons for a capture attempt.
public enum CaptureFailure: Equatable, Sendable {
    case micDenied
    case sessionInterrupted
    case engineError(String)
    case jetsamRisk
}

/// Pure state machine: events in, effects out. Total by construction — every
/// `(state, event)` pair is handled explicitly (see `handle`). Nothing here
/// touches the OS; the driver interprets `Effect`s.
public struct CaptureFlow: Equatable, Sendable {

    public enum Event: Sendable, Equatable {
        /// A capture was requested by some trigger.
        case trigger(CaptureTrigger)
        /// The audio session is live and the tap is delivering samples.
        case audioReady
        /// A new input level sample (RMS), for UI.
        case level(Float)
        /// `SilenceAutoStop` fired — end capture, still transcribe.
        case silenceStopped
        /// The user tapped stop — end capture, still transcribe.
        case manualStop
        /// Discard everything and return to idle.
        case cancel
        /// The engine produced its final transcript text.
        case engineFinal(String)
        /// The driver finished running `TranscriptCleaner` on the raw text (the
        /// response to a `.clean` effect). Publishing only ever happens from
        /// here — raw engine text can never reach a `.publish` effect.
        case cleaned(text: String)
        /// The engine errored.
        case engineError(String)
        /// The audio session was interrupted (call, Siri, route loss).
        case interrupted
    }

    public enum Effect: Sendable, Equatable {
        case startAudio
        case stopAudio
        case startEngine(language: String)
        /// Tear down the transcription engine. `cancel: false` lets an in-flight
        /// decode finish and deliver its final (normal stop); `cancel: true`
        /// discards it (abort paths). Engine teardown is NEVER implicit — it is
        /// always an explicit effect the driver executes literally (§6.2).
        case stopEngine(cancel: Bool)
        case clean(raw: String)
        case publish(text: String, source: PendingTranscript.Source)
        case updateActivity(CaptureState)
        case endActivity
        case abort(CaptureFailure)
    }

    public private(set) var state: CaptureState

    /// The language handed to the engine when it starts. Fixed at construction
    /// for now (per-mode language routing is WP3); kept explicit so `startEngine`
    /// is not a magic constant.
    private let language: String

    /// Remembers what kind of trigger started the in-flight capture so the
    /// eventual `publish` can be stamped with the right `PendingTranscript.Source`.
    private var activeTrigger: CaptureTrigger?

    public init(state: CaptureState = .idle, language: String = "en") {
        self.state = state
        self.language = language
        self.activeTrigger = nil
    }

    /// Maps a trigger to the source stamped on the published transcript.
    private static func source(for trigger: CaptureTrigger?) -> PendingTranscript.Source {
        switch trigger {
        case .appIntent: return .appIntent
        case .keyboardHandoff: return .appSwitch
        case .inApp, .none: return .inApp
        }
    }

    /// Advance the machine. Returns the effects the driver must execute, in order.
    ///
    /// Design rules enforced below:
    /// - `cancel` is always honored: from any live state it tears down and returns
    ///   to `idle`; from `idle`/`published`/`failed` it is a no-op (nothing to cancel).
    /// - `interrupted` is a hard abort while capturing/preparing/listening.
    /// - `engineError` aborts only when it is meaningful (during/after capture).
    /// - Events that don't apply to the current state are ignored (no effects,
    ///   no state change) rather than crashing — the machine is total.
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {

        // MARK: idle
        case (.idle, .trigger(let trigger)):
            activeTrigger = trigger
            state = .preparing
            return [.startAudio, .updateActivity(.preparing)]

        case (.idle, _):
            // Nothing to do when nothing is running.
            return []

        // MARK: preparing
        case (.preparing, .audioReady):
            state = .listening(level: 0)
            return [.startEngine(language: language), .updateActivity(.listening(level: 0))]

        case (.preparing, .cancel):
            // The engine has not started yet (that happens on audioReady), so there
            // is nothing to stop — only the audio session to release.
            return abortToIdle(stopAudio: true, stopEngine: .none, failure: nil)

        case (.preparing, .interrupted):
            return abortToIdle(stopAudio: true, stopEngine: .none, failure: .sessionInterrupted)

        case (.preparing, .engineError(let message)):
            return abortToIdle(stopAudio: true, stopEngine: .none, failure: .engineError(message))

        case (.preparing, .trigger),
             (.preparing, .level),
             (.preparing, .silenceStopped),
             (.preparing, .manualStop),
             (.preparing, .engineFinal),
             (.preparing, .cleaned):
            // Premature or duplicate signals before audio is live — ignore.
            return []

        // MARK: listening
        case (.listening, .level(let value)):
            state = .listening(level: value)
            return [.updateActivity(.listening(level: value))]

        case (.listening, .silenceStopped),
             (.listening, .manualStop):
            // Normal stop: end audio, let the engine finish its decode (cancel:
            // false), then transcribe. Engine teardown is explicit, never implicit.
            state = .transcribing
            return [.stopAudio, .stopEngine(cancel: false), .updateActivity(.transcribing)]

        case (.listening, .cancel):
            // Abort while listening: stop audio AND cancel the engine's decode.
            return abortToIdle(stopAudio: true, stopEngine: .cancel, failure: nil)

        case (.listening, .interrupted):
            return abortToIdle(stopAudio: true, stopEngine: .cancel, failure: .sessionInterrupted)

        case (.listening, .engineError(let message)):
            // engineError means the engine is already dead — do NOT re-stop it.
            return abortToIdle(stopAudio: true, stopEngine: .none, failure: .engineError(message))

        case (.listening, .trigger),
             (.listening, .audioReady),
             (.listening, .engineFinal),
             (.listening, .cleaned):
            // Already listening; a second trigger/audioReady is redundant, and a
            // final can't arrive before we stop the audio in this design.
            return []

        // MARK: transcribing
        case (.transcribing, .engineFinal(let raw)):
            // Raw text goes out ONLY as a clean request. The driver runs
            // TranscriptCleaner and feeds the result back as `.cleaned`, which
            // is the sole path to a `.publish` effect — a driver that executes
            // effects literally can never ship uncleaned text.
            return [.clean(raw: raw)]

        case (.transcribing, .cleaned(let text)):
            let source = Self.source(for: activeTrigger)
            return [.publish(text: text, source: source)]

        case (.transcribing, .cancel):
            // Audio is already stopped; cancel the in-flight decode so it does not
            // complete wastefully (the engine is still running until we stop it).
            return abortToIdle(stopAudio: false, stopEngine: .cancel, failure: nil)

        case (.transcribing, .engineError(let message)):
            // engineError means the engine is already dead — do NOT re-stop it.
            return abortToIdle(stopAudio: false, stopEngine: .none, failure: .engineError(message))

        case (.transcribing, .interrupted):
            // Audio is already stopped; interruption during transcription cancels
            // the (finishing) engine so nothing is published.
            return abortToIdle(stopAudio: false, stopEngine: .cancel, failure: .sessionInterrupted)

        case (.transcribing, .trigger),
             (.transcribing, .audioReady),
             (.transcribing, .level),
             (.transcribing, .silenceStopped),
             (.transcribing, .manualStop):
            // Capture already ended; these no longer apply.
            return []

        // MARK: published (terminal-ish; a new trigger restarts)
        case (.published, .trigger(let trigger)):
            activeTrigger = trigger
            state = .preparing
            return [.startAudio, .updateActivity(.preparing)]

        case (.published, .cancel):
            // Nothing live to cancel; just drop the activity so the UI clears.
            activeTrigger = nil
            state = .idle
            return [.endActivity]

        case (.published, _):
            return []

        // MARK: failed (terminal-ish; a new trigger restarts)
        case (.failed, .trigger(let trigger)):
            activeTrigger = trigger
            state = .preparing
            return [.startAudio, .updateActivity(.preparing)]

        case (.failed, .cancel):
            activeTrigger = nil
            state = .idle
            return [.endActivity]

        case (.failed, _):
            return []
        }
    }

    /// Records a successful publish. The driver calls this once it has actually
    /// written the `PendingTranscript`, so the machine's state reflects reality.
    /// Kept separate from `handle` because the id is only known after the store
    /// write. Returns the Live Activity effects (show "published", then end) so
    /// the activity teardown is part of the tested contract, not a driver
    /// convention.
    @discardableResult
    public mutating func didPublish(id: PendingTranscript.ID) -> [Effect] {
        activeTrigger = nil
        state = .published(id)
        return [.updateActivity(.published(id)), .endActivity]
    }

    /// Whether an abort should also tear down the engine, and how.
    private enum EngineTeardown {
        /// Leave the engine alone (it was never started, or already died on error).
        case none
        /// Stop the engine and discard any pending decode.
        case cancel
    }

    /// Common teardown: stop audio (if still running), tear down the engine (if it
    /// is live), end the activity, and either fail or go idle. Engine teardown is
    /// always an explicit `.stopEngine` effect — never a side effect of another
    /// effect (§6.2 literal-effects doctrine).
    private mutating func abortToIdle(
        stopAudio: Bool, stopEngine: EngineTeardown, failure: CaptureFailure?
    ) -> [Effect] {
        activeTrigger = nil
        var effects: [Effect] = []
        if stopAudio {
            effects.append(.stopAudio)
        }
        if case .cancel = stopEngine {
            effects.append(.stopEngine(cancel: true))
        }
        if let failure {
            state = .failed(failure)
            effects.append(.abort(failure))
        } else {
            state = .idle
            effects.append(.endActivity)
        }
        return effects
    }
}

/// The host-side driver (implemented in CaptureKit): owns the `AVAudioSession`
/// config, the iOS `AudioCapture` conformer, the streaming engine, `SilenceAutoStop`,
/// `TranscriptCleaner`, and executes the `CaptureFlow` effects. `@MainActor` because
/// it drives UI-facing state (the Live Activity, waveform) and owns single-threaded
/// mutable orchestration state — the driver runs entirely on the main actor rather
/// than hopping per method. Declared here so MobileCore-side callers can depend on
/// the seam.
@MainActor
public protocol CaptureCoordinating: AnyObject {
    var state: CaptureState { get }
    var onStateChange: ((CaptureState) -> Void)? { get set }
    func begin(trigger: CaptureTrigger) async
    /// User stop — capture ends but transcription still runs.
    func stop() async
    /// Discard everything.
    func cancel() async
}
