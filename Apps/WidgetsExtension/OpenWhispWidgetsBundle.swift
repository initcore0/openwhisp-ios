import WidgetKit
import SwiftUI

/// The widget extension bundle. WP1 ships a single compiling stub widget so the
/// target builds and installs; the "listening…" Live Activity and the Control
/// Center recording control (the iOS-18 `AudioRecordingIntent` surface) land in
/// WP5.
@main
struct OpenWhispWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
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
