import Foundation
import OpenWhispCore

// MARK: - Scripted fake engine (UI-test only, DEBUG-gated)
//
// XCUITest must be able to drive the WHOLE floor flow (deep link -> dictation
// sheet -> capture -> publish) on the simulator, where there is no mic and no
// downloaded model. This engine stands in for a real `StreamingTranscriptionEngine`.
//
// It reproduces a real utterance's LEVEL SHAPE so the coordinator's real
// `SilenceAutoStop` fires exactly as it would with a live mic — no special stop
// hook, no reaching into the flow: on `start` it emits a short burst of
// speech-level samples (arming the detector) followed by silence-level samples
// spaced over real time, so continuous silence accumulates past `silenceToStop`
// and the coordinator itself decides to stop. The engine's final is then
// delivered on the coordinator's normal `stop(cancel: false)`. This keeps the
// fake faithful to the real hands-free path the hero/floor flows depend on.
//
// It is compiled ONLY in DEBUG (`#if DEBUG`). The host wires it in solely when the
// `-openwhisp-uitest-fake-engine` launch argument is present; a Release build has
// neither this type nor that code path (see `scriptedFakeEngineRequested`, which
// hard-returns false in Release, asserted by a package test).

#if DEBUG
/// A deterministic `StreamingTranscriptionEngine` for UI tests: no mic, no model,
/// no network. Plays a speech-then-silence level curve so the coordinator's real
/// `SilenceAutoStop` ends capture, then delivers `Self.fakeFinalText` as the final.
public final class ScriptedFakeEngine: StreamingTranscriptionEngine {
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    public var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?
    public var onStarted: (() -> Void)?

    /// The fixed transcript a UI test asserts on. Deliberately already
    /// well-formed so the cleaner is a near no-op and the assertion is stable
    /// across cleaner tweaks.
    public static let fakeFinalText = "This is a scripted dictation for UI testing."

    /// Spacing between the scripted level ticks. The speech burst + silence run
    /// together take ~`tick * (speechTicks + silenceTicks)` seconds; sized so the
    /// sheet's "listening" state is visible to screenshot, and so the coordinator's
    /// default `SilenceAutoStop` (silenceToStop 1.5s, minSpeechToArm 0.30s) fires.
    private let tick: TimeInterval
    private let speechTicks: Int
    private let silenceTicks: Int

    private var scheduled: [DispatchWorkItem] = []
    private var started = false

    public init(tick: TimeInterval = 0.1, speechTicks: Int = 6, silenceTicks: Int = 20) {
        self.tick = tick
        self.speechTicks = speechTicks
        self.silenceTicks = silenceTicks
    }

    public func selectDevice(_ deviceID: String) {}

    public func start(language: String) throws {
        started = true
        onStarted?()
        onPartial?(Self.fakeFinalText)

        // Speech burst: arms the silence detector.
        var index = 0
        for _ in 0..<speechTicks {
            schedule(at: Double(index) * tick, level: 0.6)
            index += 1
        }
        // Silence run: continuous sub-threshold samples so SilenceAutoStop fires.
        // Once it fires, the coordinator calls stop(cancel:false), which delivers
        // the final — so the trailing ticks after the fire are harmless no-ops.
        for _ in 0..<silenceTicks {
            schedule(at: Double(index) * tick, level: 0.02)
            index += 1
        }
    }

    private func schedule(at delay: TimeInterval, level: Float) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.onLevelChanged?(level, level)
        }
        scheduled.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func stop(cancel: Bool) {
        started = false
        scheduled.forEach { $0.cancel() }
        scheduled.removeAll()
        if cancel { return }
        // Normal stop (from the coordinator, on silence/manual stop): deliver the
        // scripted final so it flows through clean -> publish.
        onFinal?(Self.fakeFinalText)
    }
}
#endif

/// Whether the UI-test scripted-fake engine should be used, based on process
/// launch arguments. In RELEASE this ALWAYS returns false — the fake path cannot
/// be activated in a shipped build even if the argument were somehow present, and
/// the `ScriptedFakeEngine` type does not exist to be constructed. A package test
/// asserts this Release behavior.
public func scriptedFakeEngineRequested(
    arguments: [String] = ProcessInfo.processInfo.arguments
) -> Bool {
    #if DEBUG
    return arguments.contains("-openwhisp-uitest-fake-engine")
    #else
    return false
    #endif
}
