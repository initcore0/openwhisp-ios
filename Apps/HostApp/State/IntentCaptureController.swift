import Foundation
import AVFoundation
import MobileCore
import CaptureKit
import OpenWhispCore

/// The host-process capture owner for the HERO flow (ARCHITECTURE §5.1). When
/// `StartDictationIntent` runs — from the Action button / Control Center — it calls
/// `IntentDictationBridge.begin()`, which this controller services: it builds a
/// `CaptureCoordinator` around the REAL App Group `HandoffEnvironment` and starts
/// capture with trigger `.appIntent`, driving the same publish + Live Activity path
/// as the floor flow's sheet. No SwiftUI view is required, because the intent may
/// run while the app is backgrounded.
///
/// R0a CAVEAT: whether `AVAudioEngine` can actually start from a
/// background/not-running intent is the unverified real-device unknown. `begin()`
/// RETURNS whether capture reached `.listening`/`.preparing`; if it never does
/// (e.g. session activation is denied in the background), the caller degrades to
/// opening the app (`openAppWhenRun` path).
@MainActor
final class IntentCaptureController {
    static let shared = IntentCaptureController()

    private let settings: AppSettings
    private var coordinator: CaptureCoordinator?
    private var environment: HandoffEnvironment?

    /// Set by the app so the intent's open-app fallback can present the sheet.
    var onRequestOpenApp: (() -> Void)?

    private init() {
        // Reads UserDefaults, so it agrees with the app's settings even though it's
        // a distinct instance (the intent may run before the app's @StateObjects
        // exist). History is not appended on the background intent path — the
        // transcript still lands in the App Group and the keyboard inserts it.
        self.settings = AppSettings()
        self.environment = HandoffEnvironment.live()
    }

    /// Install the bridge handlers so App Intents route here. Called once at launch.
    func install() {
        IntentDictationBridge.shared.beginHandler = { [weak self] in
            await self?.beginFromIntent() ?? false
        }
        IntentDictationBridge.shared.stopHandler = { [weak self] in
            await self?.coordinator?.stop()
        }
        IntentDictationBridge.shared.openAppHandler = { [weak self] in
            self?.onRequestOpenApp?()
        }
    }

    /// Begin capture from an App Intent. Returns true if capture started in-process.
    private func beginFromIntent() async -> Bool {
        guard let environment else { return false }

        // Mic permission must already be granted (an intent can't present the
        // system prompt from the background); a denial fails the start so the
        // caller opens the app to resolve it.
        let permission = AVAudioApplication.shared.recordPermission
        guard permission == .granted else { return false }

        let engine = ParakeetOrWhisper(settings: settings)
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: IOSAudioSessionController(),
            handoffStore: environment.store,
            notifier: environment.notifier,
            sharedState: environment.sharedState,
            cleanerConfig: settings.cleanerConfig(),
            language: settings.languageHint
        )
        coordinator.onStateChange = { state in
            Task { @MainActor in
                LiveActivityController.shared.update(DictationActivityState.from(state))
                if case .published = state { LiveActivityController.shared.finish() }
                if case .failed = state { LiveActivityController.shared.end() }
            }
        }
        self.coordinator = coordinator

        LiveActivityController.shared.start(trigger: .appIntent)
        await coordinator.begin(trigger: .appIntent)

        // Did capture actually reach a live state? (Session activation may fail in
        // the background — the R0a unknown.) If not, tear the activity down and
        // report failure so the intent opens the app instead.
        switch coordinator.state {
        case .preparing, .listening, .transcribing:
            return true
        default:
            LiveActivityController.shared.end()
            return false
        }
    }
}

/// Build the user-selected streaming engine (shared with the composer/sheet logic).
@MainActor
private func ParakeetOrWhisper(settings: AppSettings) -> StreamingTranscriptionEngine {
    switch settings.engineFamily {
    case .parakeet:
        return ParakeetMobileEngine(variantID: settings.parakeetVariant)
    case .whisperKit:
        return WhisperKitMobileEngine(modelName: settings.whisperModel)
    }
}
