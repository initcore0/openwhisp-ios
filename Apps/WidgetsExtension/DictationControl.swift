import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Control Center control (ARCHITECTURE §5.1 hero surface)
//
// An iOS-18 `ControlWidget` that launches `StartDictationIntent` — the sanctioned
// no-app-switch dictation trigger [C10/C11]. The user adds it to Control Center (or
// assigns the Action button to it) via the setup walkthrough in host Settings.
//
// `AudioRecordingIntent` conformance on the intent is what allows the capture to
// start without foregrounding the app; whether that succeeds from every surface is
// the R0a real-device unknown (docs/TESTING.md tier-4).

@available(iOS 18.0, *)
struct DictationControl: ControlWidget {
    static let kind = "app.openwhisp.ios.control.dictation"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartDictationIntent()) {
                Label("Dictate", systemImage: "mic.fill")
            }
        }
        .displayName("OpenWhisp Dictation")
        .description("Start on-device dictation without switching apps.")
    }
}
