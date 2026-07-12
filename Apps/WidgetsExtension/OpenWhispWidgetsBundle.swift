import WidgetKit
import SwiftUI

/// The widget extension bundle. Carries the WP5 hero surfaces: the dictation Live
/// Activity ("Listening…" with a Stop button + Dynamic Island) and the Control
/// Center control that launches `StartDictationIntent`. The WP1 placeholder widget
/// stays so the extension always has a Home-Screen presence.
@main
struct OpenWhispWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
        if #available(iOS 18.0, *) {
            DictationLiveActivity()
            DictationControl()
        }
    }
}

struct PlaceholderWidget: Widget {
    let kind = "OpenWhispPlaceholderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaceholderProvider()) { entry in
            PlaceholderWidgetView(entry: entry)
        }
        .configurationDisplayName("OpenWhisp")
        .description("Dictation status (coming soon).")
        .supportedFamilies([.systemSmall])
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: Date())], policy: .never))
    }
}

struct PlaceholderWidgetView: View {
    let entry: PlaceholderEntry

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "mic.fill")
            Text("OpenWhisp")
                .font(.caption)
        }
    }
}
