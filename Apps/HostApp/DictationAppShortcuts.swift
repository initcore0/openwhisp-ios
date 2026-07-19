import AppIntents

/// Registers the dictation intents as App Shortcuts. Without this provider the
/// intents exist but are INVISIBLE in the hero surfaces the Settings walkthrough
/// points at — the Action button's "Choose a Shortcut" picker and the Shortcuts
/// gallery only list App Shortcuts, not bare intents. Host-app target ONLY: the
/// system extracts App Shortcuts from the app bundle, and the widget process
/// must not declare a competing provider.
@available(iOS 18.0, *)
struct OpenWhispAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start \(.applicationName) dictation",
                "Dictate with \(.applicationName)",
                "Start dictation in \(.applicationName)",
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopDictationIntent(),
            phrases: [
                "Stop \(.applicationName) dictation",
            ],
            shortTitle: "Stop Dictation",
            systemImageName: "stop.fill"
        )
    }
}
