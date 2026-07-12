import Foundation
import MobileCore
import OpenWhispCore
@testable import CaptureKit

// MARK: - Protocol fakes for engine-agnostic coordinator tests
//
// These let `CaptureKitTests` drive `CaptureCoordinator` end-to-end with NO
// network, NO models, NO simulator, NO mic — the always-green `swift test` gate.
// Model-dependent real-engine paths live behind OPENWHISP_E2E_ENGINES=1 (see
// RealEngineE2ETests).

/// A `StreamingTranscriptionEngine` whose partials/finals/errors/levels are pushed
/// by the test, so the coordinator's event wiring can be exercised deterministically.
final class FakeStreamingEngine: StreamingTranscriptionEngine {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?
    var onStarted: (() -> Void)?

    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var lastLanguage: String?
    /// If set, `start` throws it (to exercise the engine-error start path).
    var startError: Error?

    func selectDevice(_ deviceID: String) {}

    func start(language: String) throws {
        if let startError { throw startError }
        startCount += 1
        lastLanguage = language
    }

    func stop(cancel: Bool) {
        if cancel { cancelCount += 1 } else { stopCount += 1 }
    }

    // Test drivers:
    func emitLevel(display: Float, vad: Float) { onLevelChanged?(display, vad) }
    func emitStarted() { onStarted?() }
    func emitPartial(_ text: String) { onPartial?(text) }
    func emitFinal(_ text: String) { onFinal?(text) }
    func emitError(_ message: String) { onError?(message) }
}

/// An `AudioSessionControlling` fake that records activation/deactivation, can be
/// made to fail activation (to exercise the interrupted path), and can fire an
/// interruption on demand (to exercise the mid-capture interruption path).
final class FakeAudioSession: AudioSessionControlling {
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    var activationError: Error?
    var onInterruption: (() -> Void)?

    func activate() throws {
        if let activationError { throw activationError }
        activateCount += 1
    }
    func deactivate() { deactivateCount += 1 }

    /// Simulate the OS interrupting the live session (phone call / Siri / route
    /// loss) — drives the coordinator's `.interrupted` dispatch.
    func fireInterruption() { onInterruption?() }
}

/// A `HandoffNotifier` fake that counts pings.
final class FakeNotifier: HandoffNotifier {
    var onPublished: (() -> Void)?
    private(set) var notifyCount = 0
    func notifyPublished() { notifyCount += 1 }
}

struct FakeError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Cleaner config helpers

enum TestCleaner {
    /// A cleaner config with ONE vocabulary substitution ("gpt" → "GPT") and smart
    /// formatting on, so a raw transcript ("gpt is great") cleans to a DIFFERENT
    /// string ("GPT is great.") — the tests assert the PUBLISHED text is the cleaned
    /// one, which fails loudly if raw text ever reaches publish.
    static func config() -> TranscriptCleaner.Config {
        TranscriptCleaner.Config(
            language: "en",
            customVocabularyEnabled: true,
            substitutions: [
                Vocabulary.Substitution(from: "gpt", to: "GPT"),
            ],
            smartFormattingEnabled: true,
            fillerRemovalEnabled: false,
            spokenPunctuationEnabled: false
        )
    }

    /// The expected cleaned output for the raw transcript used in tests, computed
    /// through the SAME cleaner the coordinator uses — so the assertion tracks the
    /// real cleaner behavior rather than a hardcoded guess.
    static func expected(for raw: String) -> String {
        TranscriptCleaner(config: config()).clean(raw, isFinalTranscript: true)
    }
}
