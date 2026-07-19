import Foundation
import Combine
import AVFoundation
import MobileCore
import CaptureKit
import OpenWhispCore

/// Drives the in-app dictation composer (ARCHITECTURE §5 flow #3): builds a
/// `CaptureCoordinator` around the selected streaming engine, exposes the live
/// `CaptureState`, streaming partials, a rolling level for the waveform, and the
/// final CLEANED text. Thin — all the sequencing lives in the tested `CaptureFlow`
/// state machine; this view model only mirrors it into `@Published` UI state and
/// appends finished text to history.
///
/// The composer publishes with `source: .inApp` into an in-memory handoff store
/// (the App Group store is a WP5 concern); when a transcript lands there, we read
/// it back as the final text.
@MainActor
final class CaptureViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case transcribing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Live streaming partial (uncleaned) shown while listening.
    @Published private(set) var partial: String = ""
    /// The final, cleaned, editable text.
    @Published var finalText: String = ""
    /// Rolling recent levels (0…1) for the waveform, newest last.
    @Published private(set) var levels: [Float] = []
    /// Whether mic permission has been denied (drives an inline explainer).
    @Published private(set) var micDenied: Bool = false
    /// True while a capture's "Preparing…" includes staging the model for the
    /// first time (a large download) — the UI says so instead of looking hung.
    @Published private(set) var isFirstUseDownload: Bool = false

    private let settings: AppSettings
    private let history: HistoryStore
    private let handoff = InMemoryHandoffStore()
    private var coordinator: CaptureCoordinator?
    private var lastRawFinal: String = ""

    private let maxLevels = 48

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .listening, .transcribing: return true
        case .idle, .failed: return false
        }
    }

    // MARK: - Controls

    func toggle() {
        switch phase {
        case .idle, .failed:
            Task { await begin() }
        case .listening, .preparing:
            Task { await coordinator?.stop() }
        case .transcribing:
            break // let it finish
        }
    }

    func cancel() {
        Task { await coordinator?.cancel() }
        partial = ""
        levels = []
        if case .failed = phase {} else { phase = .idle }
    }

    private func begin() async {
        // Ask for mic permission up front; a denial surfaces an inline explainer
        // rather than a dead record button.
        let granted = await Self.requestMicPermission()
        guard granted else {
            micDenied = true
            phase = .failed("Microphone access is off. Enable it in Settings to dictate.")
            return
        }
        micDenied = false
        partial = ""
        finalText = ""
        levels = []
        lastRawFinal = ""

        // Honest first-use state: when the active model isn't on disk yet, the
        // engine's start will trigger the (multi-hundred-MB) self-staging
        // download — surface that instead of a bare "Preparing…".
        isFirstUseDownload = !EngineCache.shared.isModelStaged(settings.engineSelection)

        let engine = makeStreamingEngine()
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: IOSAudioSessionController(),
            handoffStore: handoff,
            cleanerConfig: settings.cleanerConfig(),
            language: settings.languageHint
        )
        coordinator.onStateChange = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        coordinator.onRawFinal = { [weak self] raw in
            self?.lastRawFinal = raw
        }
        coordinator.onPartial = { [weak self] text in
            Task { @MainActor in self?.partial = text }
        }
        self.coordinator = coordinator
        await coordinator.begin(trigger: .inApp)
    }

    private func makeStreamingEngine() -> StreamingTranscriptionEngine {
        // Shared warm instance — a fresh engine per capture re-loads the CoreML
        // models from disk every time (seconds of "Preparing…" per dictation).
        EngineCache.shared.engine(for: settings.engineSelection)
    }

    // MARK: - State mirroring

    private func apply(_ state: CaptureState) {
        switch state {
        case .idle:
            phase = .idle
        case .preparing:
            phase = .preparing
        case .listening(let level):
            phase = .listening
            pushLevel(level)
        case .transcribing:
            phase = .transcribing
        case .published(let id):
            // Read the cleaned transcript back out of the handoff store.
            if let t = try? handoff.peek(), t.id == id {
                finalText = t.text
                history.append(text: t.text, rawText: lastRawFinal.isEmpty ? nil : lastRawFinal)
                try? handoff.discardAll()
            }
            partial = ""
            phase = .idle
        case .failed(let failure):
            phase = .failed(Self.describe(failure))
        }
    }

    private func pushLevel(_ level: Float) {
        levels.append(min(1, max(0, level)))
        if levels.count > maxLevels {
            levels.removeFirst(levels.count - maxLevels)
        }
    }

    // MARK: - Helpers

    private static func describe(_ failure: CaptureFailure) -> String {
        switch failure {
        case .micDenied: return "Microphone access is off. Enable it in Settings to dictate."
        case .sessionInterrupted: return "Recording was interrupted (a call or another app took the mic)."
        case .engineError(let m): return m
        case .jetsamRisk: return "Not enough memory to run this model. Try a smaller one in Settings."
        }
    }

    static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
