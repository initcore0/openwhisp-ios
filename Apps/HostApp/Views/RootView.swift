import SwiftUI

/// The app's root: onboarding on first launch, otherwise the main TabView
/// (Dictate / History / Settings). Views are thin; state lives in the injected
/// stores + view models.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if settings.didOnboard {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            DictateView()
                .tabItem { Label("Dictate", systemImage: "mic.fill") }
                .accessibilityIdentifier("tab.dictate")

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.fill") }
                .accessibilityIdentifier("tab.history")

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .accessibilityIdentifier("tab.settings")
        }
    }
}
