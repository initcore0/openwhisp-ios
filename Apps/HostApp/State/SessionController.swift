import Foundation
import Combine
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
import MobileCore
import CaptureKit
import OpenWhispCore

/// The host-process owner of a Dictation Session (WP10b, ARCHITECTURE §6.8). It
/// builds the `SessionHolder` driver around the REAL App Group stores + a
/// `CaptureCoordinator`, and exposes a thin, observable surface the arming screen
/// binds to. One instance app-wide (an `@StateObject` on `OpenWhispApp`).
///
/// The arming flow (§5 flow 1.5, D11): the keyboard mic key with no session hops here
/// via `openwhisp://session/arm`; `arm()` activates the background audio session +
/// keep-alive tap and publishes `armed`; the user swipes back to their app and the
/// keyboard mic key then drives capture instantly for the rest of the window. The
/// session ends on the idle timeout, the End Session button (app / Live Activity), an
/// unrecoverable interruption, or app termination.
///
/// R0a/R10a CAVEAT: whether iOS actually keeps the process alive under the `audio`
/// background mode across a locked / other-app-foreground / Low-Power-Mode armed
/// window is the real-device unknown the WP10b spike measures (docs/TESTING.md). The
/// state machine + wiring are correct by test; survival is a device pass.
@MainActor
final class SessionController: ObservableObject {

    /// The session phase mirrored for the arming screen. Driven off the status the
    /// driver publishes (read back from the store on each notify).
    @Published private(set) var phase: SessionStatus.Phase = .off
    /// When the current armed session expires (nil = `.never`), for the countdown.
    @Published private(set) var expiresAt: Date?
    /// An inline failure (App Group unavailable, audio activation denied).
    @Published private(set) var failure: String?

    var isArmed: Bool { phase != .off }

    private let settings: AppSettings
    private let handoff: HandoffEnvironment?
    private let session: SessionEnvironment?
    private var holder: SessionHolder?
    private var commandListener: SessionCommandDarwinListener?

    init(settings: AppSettings,
         handoff: HandoffEnvironment? = HandoffEnvironment.live(),
         session: SessionEnvironment? = SessionEnvironment.live()) {
        self.settings = settings
        self.handoff = handoff
        self.session = session
    }

    /// Install the End Session intent bridge handler so the Live Activity button (and
    /// Shortcuts) reach this controller. Called once at launch.
    func install() {
        IntentDictationBridge.shared.endSessionHandler = { [weak self] in
            self?.endSession()
        }
        #if canImport(UIKit)
        // Clean teardown on process termination (release the audio session, drop the
        // status to `.off`). The keyboard's 30 s staleness fence catches a hard kill,
        // but a graceful terminate is honest and immediate.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
        #endif
    }

    /// Arm a session (the `openwhisp://session/arm` hop / arming screen appearing).
    /// Builds the holder lazily so the coordinator is fresh for each armed window.
    func arm() {
        guard let handoff, let session else {
            failure = "Dictation sessions are unavailable (App Group not configured)."
            return
        }
        failure = nil

        // A capture coordinator built on the REAL handoff store — capture inside the
        // session publishes cleaned text there exactly as the floor flow does, so the
        // keyboard consumes + inserts finals through the same WP5 path.
        let engine = makeEngine()
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: IOSAudioSessionController(),
            handoffStore: handoff.store,
            notifier: handoff.notifier,
            sharedState: handoff.sharedState,
            cleanerConfig: settings.cleanerConfig(),
            language: settings.languageHint
        )

        let holder = SessionHolder(
            coordinator: coordinator,
            audio: IOSSessionKeepAlive(),
            timers: DispatchSessionTimers(),
            commandMailbox: session.commandMailbox,
            partialStore: session.partialStore,
            statusStore: session.statusStore,
            activity: SessionActivityBridge(),
            // Resolve the CLEANED published text by peeking the handoff store (the same
            // peek the composer/sheet do) so the final live-partial carries clean text.
            cleanedFinal: { [handoff] id in
                let pending = try? handoff.store.peek()
                return (pending?.id == id) ? pending?.text : nil
            },
            notifyStatus: { [weak self] in
                SessionDarwinPoster.postStatus()
                self?.refreshFromStore()
            },
            notifyPartial: { SessionDarwinPoster.postPartial() }
        )
        self.holder = holder

        // Wake the driver immediately on a keyboard command ping (the 250 ms poll is
        // the floor). The listener lives as long as the session.
        let listener = SessionCommandDarwinListener()
        listener.onCommand = { [weak holder] in
            Task { @MainActor in holder?.onCommandPing() }
        }
        self.commandListener = listener

        LiveActivityController.shared.startSession()
        holder.arm(config: settings.sessionConfig)
        refreshFromStore()
    }

    /// End the session explicitly (arming screen's End Session button, the Live
    /// Activity button, or Shortcuts via the intent bridge).
    func endSession() {
        holder?.endSession()
        teardown()
    }

    /// The app is terminating — tear the session down cleanly so the audio session is
    /// released and the status drops to `.off` (the keyboard's staleness fence would
    /// eventually catch a killed host, but a clean teardown is honest and immediate).
    func appWillTerminate() {
        holder?.appWillTerminate()
        teardown()
    }

    // MARK: - Internals

    private func teardown() {
        commandListener = nil
        holder = nil
        refreshFromStore()
    }

    /// Mirror the driver's just-published status into the observable surface.
    private func refreshFromStore() {
        let status = (try? session?.statusStore.read()) ?? nil
        phase = status?.phase ?? .off
        expiresAt = status?.expiresAt
    }

    private func makeEngine() -> StreamingTranscriptionEngine {
        switch settings.engineFamily {
        case .parakeet:
            return ParakeetMobileEngine(variantID: settings.parakeetVariant)
        case .whisperKit:
            return WhisperKitMobileEngine(modelName: settings.whisperModel)
        }
    }
}

/// Bridges the driver's `SessionActivityDriving` seam to `LiveActivityController`.
/// CaptureKit can't import ActivityKit, so the host app supplies this: it maps the
/// session status to the Live Activity content (armed → held session with End
/// Session; capturing/transcribing → live states) and ends the activity on teardown.
@MainActor
private final class SessionActivityBridge: SessionActivityDriving {
    func update(_ status: SessionStatus) {
        guard status.phase != .off else { LiveActivityController.shared.end(); return }
        LiveActivityController.shared.update(DictationActivityState.fromSession(status.phase))
    }
    func end() {
        LiveActivityController.shared.end()
    }
}
