import Foundation
import Combine
import AVFoundation
import MobileCore
import CaptureKit
import OpenWhispCore

/// Drives the compact DICTATION SHEET (ARCHITECTURE §5.2 floor flow, and the
/// §5.1 hero flow's foreground path). Unlike `CaptureViewModel` (the in-app
/// composer, which publishes into an in-memory store and reads the text back), this
/// view model builds its coordinator around the REAL App Group `HandoffEnvironment`:
///
///   - the cleaned transcript is published to `AppGroupHandoffStore` so the keyboard
///     can consume + insert it,
///   - `DarwinHandoffNotifier` pings the keyboard (live-insert if it's frontmost),
///   - `FileSharedStateStore` mirrors capturing/transcribing/idle so the keyboard's
///     mic key shows the real state.
///
/// It also drives a Live Activity through `LiveActivityController` so the hero
/// surfaces (Dynamic Island, Control Center) reflect the same capture.
///
/// There is NO supported API to switch back to the user's previous app [C9]; on
/// publish the sheet shows a "return to your app" hint and auto-dismisses. The
/// keyboard inserts on its next appearance (or instantly via the Darwin ping).
@MainActor
final class HandoffDictationViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case transcribing
        /// The transcript was published to the App Group; show the return hint.
        case published(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var partial: String = ""
    @Published private(set) var levels: [Float] = []

    private let settings: AppSettings
    private let history: HistoryStore
    private let environment: HandoffEnvironment?
    /// Whether to use the scripted UI-test fake engine instead of a real one.
    private let useFakeEngine: Bool
    private let trigger: CaptureTrigger

    private var coordinator: CaptureCoordinator?
    private var lastRawFinal: String = ""
    private let maxLevels = 48

    /// `environment` is injected so tests can pass a tempdir-backed one; in the app
    /// it defaults to `HandoffEnvironment.live()` (the REAL App Group). A nil
    /// environment (missing entitlement) surfaces an inline failure rather than a
    /// silent no-op.
    init(
        settings: AppSettings,
        history: HistoryStore,
        environment: HandoffEnvironment? = HandoffEnvironment.live(),
        trigger: CaptureTrigger = .keyboardHandoff,
        useFakeEngine: Bool = scriptedFakeEngineRequested()
    ) {
        self.settings = settings
        self.history = history
        self.trigger = trigger
        self.useFakeEngine = useFakeEngine
        // Prefer the REAL App Group environment. In an UNSIGNED UI-test build the
        // App Group entitlement isn't provisioned, so `live()` is nil there — fall
        // back to a temp-directory-backed environment SOLELY on the fake-engine
        // path so the floor-flow XCUITest can exercise the whole publish. Production
        // never takes this branch (the fake engine is DEBUG + launch-arg gated).
        if let environment {
            self.environment = environment
        } else if useFakeEngine {
            self.environment = Self.uiTestFallbackEnvironment()
        } else {
            self.environment = nil
        }
    }

    /// A temp-directory `HandoffEnvironment` for the UNSIGNED UI-test build, where
    /// the App Group container is unavailable. Never used in production.
    private static func uiTestFallbackEnvironment() -> HandoffEnvironment? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uitest-handoff", isDirectory: true)
        guard let store = try? AppGroupHandoffStore(directory: dir),
              let sharedState = try? FileSharedStateStore(directory: dir) else { return nil }
        return HandoffEnvironment(store: store, notifier: DarwinHandoffNotifier(), sharedState: sharedState)
    }

    var isBusy: Bool {
        switch phase {
        case .preparing, .listening, .transcribing: return true
        case .idle, .published, .failed: return false
        }
    }

    /// The published cleaned text, if the capture completed.
    var publishedText: String? {
        if case .published(let t) = phase { return t }
        return nil
    }

    // MARK: - Control

    /// Begin a handoff capture. Called when the sheet appears.
    func begin() {
        Task { await start() }
    }

    /// User tapped stop on the sheet (or the Live Activity stop button routed here).
    func stop() {
        Task { await coordinator?.stop() }
    }

    func cancel() {
        Task { await coordinator?.cancel() }
        LiveActivityController.shared.end()
    }

    private func start() async {
        guard let environment else {
            phase = .failed("Dictation handoff is unavailable (App Group not configured).")
            return
        }
        // Real captures need mic permission; the fake engine does not.
        if !useFakeEngine {
            let granted = await CaptureViewModel.requestMicPermission()
            guard granted else {
                phase = .failed("Microphone access is off. Enable it in Settings to dictate.")
                return
            }
        }
        partial = ""
        levels = []
        lastRawFinal = ""

        let engine = makeEngine()
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: IOSAudioSessionController(),
            handoffStore: environment.store,
            notifier: environment.notifier,
            sharedState: environment.sharedState,
            cleanerConfig: settings.cleanerConfig(),
            language: settings.languageHint
        )
        coordinator.onStateChange = { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        coordinator.onRawFinal = { [weak self] raw in self?.lastRawFinal = raw }
        coordinator.onPartial = { [weak self] text in
            Task { @MainActor in self?.partial = text }
        }
        self.coordinator = coordinator

        LiveActivityController.shared.start(trigger: trigger)
        await coordinator.begin(trigger: trigger)
    }

    private func makeEngine() -> StreamingTranscriptionEngine {
        #if DEBUG
        if useFakeEngine { return ScriptedFakeEngine() }
        #endif
        // Shared warm instance (see EngineCache) — never a fresh engine per capture.
        return EngineCache.shared.engine(for: settings.engineSelection)
    }

    // MARK: - State mirroring

    private func apply(_ state: CaptureState) {
        // Keep the Live Activity in lockstep with the capture pipeline.
        LiveActivityController.shared.update(DictationActivityState.from(state))

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
            // Read the cleaned transcript back for history + the "published" UI.
            // peek() (not consume) so the keyboard remains the single consumer.
            let pending = try? environment?.store.peek()
            let text = (pending?.id == id) ? (pending?.text ?? "") : ""
            if !text.isEmpty {
                history.append(text: text, rawText: lastRawFinal.isEmpty ? nil : lastRawFinal)
            }
            partial = ""
            phase = .published(text)
            // Let the Live Activity show "Inserted", then end it shortly after.
            LiveActivityController.shared.finish()
        case .failed(let failure):
            phase = .failed(Self.describe(failure))
            LiveActivityController.shared.end()
        }
    }

    private func pushLevel(_ level: Float) {
        levels.append(min(1, max(0, level)))
        if levels.count > maxLevels { levels.removeFirst(levels.count - maxLevels) }
    }

    private static func describe(_ failure: CaptureFailure) -> String {
        switch failure {
        case .micDenied: return "Microphone access is off. Enable it in Settings to dictate."
        case .sessionInterrupted: return "Recording was interrupted (a call or another app took the mic)."
        case .engineError(let m): return m
        case .jetsamRisk: return "Not enough memory to run this model. Try a smaller one in Settings."
        }
    }
}
