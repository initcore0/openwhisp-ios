import Foundation
import Combine
import MobileCore
import CaptureKit
import OpenWhispCore

/// Live-mic Engine Lab mode: dictate through the currently-selected streaming engine
/// and record a `LabRun` (no reference → WER nil; the value here is the transcript +
/// latency/RTF/RSS for a real utterance, per engine). Reuses the tested
/// `CaptureCoordinator` pipeline; measures wall-clock + RSS around the capture.
@MainActor
final class LiveMicLabViewModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, transcribing, done, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var partial = ""
    @Published private(set) var transcript = ""
    @Published private(set) var levels: [Float] = []
    @Published private(set) var lastRun: LabRun?

    private let settings: AppSettings
    private let store: LabRunStore
    private let handoff = InMemoryHandoffStore()
    private var coordinator: CaptureCoordinator?
    private var startTime: Date?
    private var rssBefore: Int64 = 0
    private let maxLevels = 48

    init(settings: AppSettings, store: LabRunStore) {
        self.settings = settings
        self.store = store
    }

    var isBusy: Bool {
        switch phase { case .listening, .transcribing: return true; default: return false }
    }

    func toggle() {
        switch phase {
        case .idle, .done, .failed:
            Task { await begin() }
        case .listening:
            Task { await coordinator?.stop() }
        case .transcribing:
            break
        }
    }

    private func begin() async {
        guard await CaptureViewModel.requestMicPermission() else {
            phase = .failed("Microphone access is off.")
            return
        }
        partial = ""; transcript = ""; levels = []
        rssBefore = LabRunner.residentSizeBytes()
        startTime = Date()

        let engine: StreamingTranscriptionEngine = settings.engineFamily == .parakeet
            ? ParakeetMobileEngine(variantID: settings.parakeetVariant)
            : WhisperKitMobileEngine(modelName: settings.whisperModel)

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
        coordinator.onPartial = { [weak self] text in
            Task { @MainActor in self?.partial = text }
        }
        self.coordinator = coordinator
        await coordinator.begin(trigger: .inApp)
    }

    private func apply(_ state: CaptureState) {
        switch state {
        case .idle:
            if case .transcribing = phase { phase = .done } else if phase != .done { phase = .idle }
        case .preparing:
            phase = .listening
        case .listening(let level):
            phase = .listening
            levels.append(min(1, max(0, level)))
            if levels.count > maxLevels { levels.removeFirst(levels.count - maxLevels) }
        case .transcribing:
            phase = .transcribing
        case .published(let id):
            if let t = try? handoff.peek(), t.id == id {
                transcript = t.text
                recordRun(text: t.text)
                try? handoff.discardAll()
            }
            phase = .done
        case .failed(let f):
            phase = .failed("\(f)")
        }
    }

    private func recordRun(text: String) {
        let latency = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let rssDelta = max(0, LabRunner.residentSizeBytes() - rssBefore)
        let selection: LabEngineSelection = settings.engineFamily == .parakeet
            ? .parakeet(variantID: settings.parakeetVariant)
            : .whisperKit(modelID: settings.whisperModel)
        let run = LabRun(
            date: startTime ?? Date(),
            engineName: selection.displayName,
            engineKind: selection.kind,
            modelID: selection.modelID,
            fixtureName: "",
            isLive: true,
            language: settings.languageHint,
            reference: "",
            hypothesis: text,
            wer: nil,
            metrics: LabMetrics(latencySeconds: latency, audioSeconds: 0, peakRSSDeltaBytes: rssDelta)
        )
        store.record(run)
        lastRun = run
    }
}
