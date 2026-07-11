import SwiftUI

/// The host app entry point. This is the "engine" target: capture + transcription
/// live here (WP3), handing finished text to the keyboard through the App Group.
/// WP1 ships only this shell so the project builds and installs.
@main
struct OpenWhispApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
