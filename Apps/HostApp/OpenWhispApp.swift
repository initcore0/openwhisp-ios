import SwiftUI
import CaptureKit

/// The host app entry point. This is the "engine" target: capture + transcription
/// live here (WP3), handing finished text to the keyboard through the App Group.
///
/// Owns the app-wide stores (settings, history, lab runs) as `@StateObject`s and
/// injects them into the environment so the thin screen views stay stateless.
@main
struct OpenWhispApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = AppSettings()
    @StateObject private var history = HistoryStore()
    @StateObject private var labRuns = LabRunStore()
    @StateObject private var dictationRouter = DictationRouter()
    /// Dictation-Session host driver front end (WP10b). Owns the armed-window
    /// `SessionHolder` and the arming screen's observable state. Given its own
    /// `AppSettings` (like `IntentCaptureController`) so the idle-timeout choice is
    /// read consistently even though it's a distinct instance.
    @StateObject private var sessionController = SessionController(settings: AppSettings())
    /// P2P sync front end (WP6). Foreground-only; auto-syncs paired Macs when the
    /// app becomes active and the peer resolves on the LAN within a short window.
    @StateObject private var sync = OpenWhispApp.makeSyncCoordinator()
    /// Remote-drive front end (WP7). Drives the paired Mac's dictate/refine/history
    /// tools over the SAME paired link; foreground-only, fail-to-journal.
    @StateObject private var remote = OpenWhispApp.makeRemoteCoordinator()

    /// Production builds a Keychain-backed sync coordinator. Under the DEBUG
    /// XCUITest `-uitest-remote-paired`/`-uitest-remote-stub` args, it's seeded
    /// with a fake paired peer so the "Your Mac" drive surface renders without a
    /// real Mac.
    private static func makeSyncCoordinator() -> SyncCoordinator {
        #if DEBUG
        if RemoteMacUITestSupport.wantsPaired {
            return SyncCoordinator(pairing: RemoteMacUITestSupport.makePairingService())
        }
        #endif
        return SyncCoordinator()
    }

    private static func makeRemoteCoordinator() -> RemoteMacCoordinator {
        #if DEBUG
        if RemoteMacUITestSupport.wantsStub {
            return RemoteMacCoordinator(
                pairing: RemoteMacUITestSupport.makePairingService(),
                clientFactory: { RemoteMacUITestSupport.makeStubClient(for: $0) })
        }
        if RemoteMacUITestSupport.wantsPaired {
            return RemoteMacCoordinator(pairing: RemoteMacUITestSupport.makePairingService())
        }
        #endif
        return RemoteMacCoordinator()
    }

    init() {
        // Install the App Intents bridge (hero flow). Its open-app fallback is wired
        // to the router below via `onRequestOpenApp` once the router exists.
        IntentCaptureController.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(labRuns)
                .environmentObject(dictationRouter)
                .environmentObject(sessionController)
                .environmentObject(sync)
                .environmentObject(remote)
                .task {
                    // Wire the App Intent's open-app fallback (background-start
                    // failure → open the app + present the sheet) to the router.
                    IntentCaptureController.shared.onRequestOpenApp = { [weak dictationRouter] in
                        dictationRouter?.present(trigger: .appIntent)
                    }
                    // Wire the End Session intent (Live Activity button / Shortcuts) to
                    // the session controller (WP10b).
                    sessionController.install()
                    // Pre-load the active model off the critical path so the first
                    // mic tap of the session starts listening near-instantly. Safe:
                    // warm() is a no-op (and never downloads) when the model isn't
                    // staged yet.
                    EngineCache.shared.warm(settings.engineSelection)
                    // Deterministic XCUITest entry: `-openwhisp-uitest-open-dictate`
                    // presents the dictation sheet on launch, exercising the SAME
                    // router path the `openwhisp://dictate` deep link takes, without
                    // depending on cross-process URL delivery timing. The REAL deep
                    // link is still driven manually (scripts/run-sim.sh) and by the
                    // simctl openurl step in the PR checklist. DEBUG-only intent.
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-openwhisp-uitest-open-dictate") {
                        dictationRouter.present(trigger: .keyboardHandoff)
                    }
                    #endif
                }
                // Floor flow (ARCHITECTURE §5.2): opening the app on
                // `openwhisp://dictate` presents the compact dictation sheet. The
                // route is parsed by the pure, tested `DeepLink.parse`; unrecognized
                // URLs are ignored here.
                .onOpenURL { url in
                    dictationRouter.handle(url: url)
                }
        }
        // Foreground-only P2P sync (ARCHITECTURE §6.5): when the app becomes
        // active, briefly browse the LAN and sync any paired Mac that resolves.
        // Fail-silent — a sleeping/absent Mac is a no-op logged to the sync
        // journal, never an error banner.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                sync.autoSyncOnForeground()
            }
            // NOTE: an armed Dictation Session is DELIBERATELY not torn down when the
            // app merely backgrounds (`.background`) — surviving the app resigning
            // active under the `audio` background mode is the whole point (D11). The
            // clean teardown happens on explicit End Session, the idle timeout, an
            // unrecoverable interruption, or `willTerminate` (below).
        }
    }
}
