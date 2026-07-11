import SwiftUI
import MobileCore

/// Placeholder home screen. Lists build info so the scaffold is verifiable on a
/// simulator/device; the real onboarding + composer land in WP3.
struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("OpenWhisp") {
                    LabeledContent("Status", value: "Scaffold (WP1)")
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "—")
                    LabeledContent("Version", value: Self.versionString)
                }
                Section("What's here") {
                    Text("Local-first dictation. Capture + on-device transcription "
                         + "will live in this host app; the keyboard extension inserts "
                         + "finished text handed off through the App Group.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Handoff seam") {
                    // Touch a MobileCore type so the app genuinely links the package.
                    LabeledContent("Handoff lifetime",
                                   value: "\(Int(PendingTranscript.defaultLifetime)) s")
                }
            }
            .navigationTitle("OpenWhisp")
        }
    }

    private static var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}

#Preview {
    HomeView()
}
