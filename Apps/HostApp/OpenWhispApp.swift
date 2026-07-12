import SwiftUI

/// The host app entry point. This is the "engine" target: capture + transcription
/// live here (WP3), handing finished text to the keyboard through the App Group.
///
/// Owns the app-wide stores (settings, history, lab runs) as `@StateObject`s and
/// injects them into the environment so the thin screen views stay stateless.
@main
struct OpenWhispApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var history = HistoryStore()
    @StateObject private var labRuns = LabRunStore()
    @StateObject private var dictationRouter = DictationRouter()

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
                .task {
                    // Wire the App Intent's open-app fallback (background-start
                    // failure → open the app + present the sheet) to the router.
                    IntentCaptureController.shared.onRequestOpenApp = { [weak dictationRouter] in
                        dictationRouter?.present(trigger: .appIntent)
                    }
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
    }
}
