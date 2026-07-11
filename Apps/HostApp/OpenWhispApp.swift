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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(history)
                .environmentObject(labRuns)
        }
    }
}
