import SwiftUI

/// A tiny, dependency-free host app that exists ONLY as a stable surface for the
/// system-keyboard typing UI test (`KeyboardTypingUITests`). It is not shipped
/// and links nothing from `OpenWhispMobileKit`, so its UI can never drift as the
/// real host app (`Apps/HostApp`) evolves — keeping the typing smoke robust and
/// owned entirely by the testing infrastructure.
///
/// Why a separate surface: the real host app's WP1 scaffold has no text field,
/// and adding one there belongs to the engines/UI work packages. Typing into a
/// text field with the SYSTEM keyboard (not our keyboard extension — enabling
/// that in XCUITest is unreliable; see docs/TESTING.md) needs a focusable field;
/// this harness provides exactly one, with a stable accessibility identifier.
@main
struct UITestHostApp: App {
    var body: some Scene {
        WindowGroup {
            UITestHostView()
        }
    }
}

struct UITestHostView: View {
    @State private var text = ""
    var body: some View {
        VStack(spacing: 24) {
            Text("UITest Host")
                .font(.headline)
            TextField("Type here", text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("uitest.textField")
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            // Echo the typed value with a stable identifier so the test can read
            // back exactly what landed in the field.
            Text(text)
                .accessibilityIdentifier("uitest.echo")
        }
        .padding()
    }
}
