import SwiftUI

/// The app's root: onboarding on first launch, otherwise the main TabView
/// (Dictate / History / Settings). Views are thin; state lives in the injected
/// stores + view models.
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var router: DictationRouter

    var body: some View {
        Group {
            if settings.didOnboard {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        // The dictation sheet is presented app-wide (floor flow + composer
        // affordance + App Intent foreground fallback) so it works over both
        // onboarding and the main tabs. Presentation is a pure function of the
        // router's `pending` state.
        .sheet(item: $router.pending) { pending in
            DictationSheet(trigger: pending.trigger)
        }
        // The Dictation-Session arming screen (WP10b) is a full-screen state — it owns
        // the whole screen so "Session on \u{2014} swipe back to your app" is the clear,
        // singular instruction. Presented by `openwhisp://session/arm`.
        .fullScreenCover(isPresented: $router.presentingSessionArm) {
            SessionArmingView()
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
