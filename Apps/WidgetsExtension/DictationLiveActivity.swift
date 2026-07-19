import WidgetKit
import SwiftUI
import AppIntents
import MobileCore

// MARK: - Dictation Live Activity (ARCHITECTURE §5.1 hero surface)
//
// Renders the "Listening…" activity on the Lock Screen + Dynamic Island while the
// host captures, ending on a brief "Inserted" confirmation. The content is the
// pure, tested `DictationActivityState`; the Stop button fires `StopDictationIntent`
// (defined in the shared Intents source, compiled into this extension too).

@available(iOS 18.0, *)
struct DictationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            LockScreenView(state: context.state)
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            dynamicIsland(context.state)
        }
    }

    // MARK: Dynamic Island

    private func dynamicIsland(_ state: DictationActivityState) -> DynamicIsland {
        DynamicIsland {
            // Expanded presentation.
            DynamicIslandExpandedRegion(.leading) {
                Label {
                    Text(state.label)
                } icon: {
                    Image(systemName: state.symbolName)
                        .foregroundStyle(tint(state))
                }
                .font(.caption)
            }
            DynamicIslandExpandedRegion(.trailing) {
                if state.isSessionArmed {
                    endSessionButton.labelStyle(.iconOnly)
                } else if !state.isTerminal {
                    stopButton.labelStyle(.iconOnly)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                LevelBar(level: state.level, active: state.phase == .listening)
                    .frame(height: 8)
            }
        } compactLeading: {
            Image(systemName: state.symbolName)
                .foregroundStyle(tint(state))
        } compactTrailing: {
            if state.phase == .listening {
                LevelBar(level: state.level, active: true)
                    .frame(width: 22, height: 8)
            } else if state.isTerminal {
                Image(systemName: state.symbolName).foregroundStyle(tint(state))
            }
        } minimal: {
            Image(systemName: state.symbolName)
                .foregroundStyle(tint(state))
        }
    }

    private var stopButton: some View {
        Button(intent: StopDictationIntent()) {
            Label("Stop", systemImage: "stop.fill")
        }
        .tint(.red)
    }

    private var endSessionButton: some View {
        Button(intent: EndSessionIntent()) {
            Label("End Session", systemImage: "xmark.circle.fill")
        }
        .tint(.red)
    }

    private func tint(_ state: DictationActivityState) -> Color {
        switch state.phase {
        case .starting: return .secondary
        case .listening: return .accentColor
        case .transcribing: return .blue
        case .inserted: return .green
        case .failed: return .red
        case .armed: return .accentColor
        }
    }
}

// MARK: - Lock Screen view

@available(iOS 18.0, *)
private struct LockScreenView: View {
    let state: DictationActivityState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.symbolName)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.label)
                    .font(.headline)
                if state.phase == .listening {
                    LevelBar(level: state.level, active: true)
                        .frame(height: 10)
                } else if state.phase == .armed {
                    Text("Dictate from your keyboard's mic key.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if state.phase == .starting || state.phase == .transcribing {
                    Text("On-device — nothing leaves your phone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.isSessionArmed {
                Button(intent: EndSessionIntent()) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("End Session")
            } else if !state.isTerminal {
                Button(intent: StopDictationIntent()) {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Stop")
            }
        }
        .padding()
    }

    private var tint: Color {
        switch state.phase {
        case .starting: return .secondary
        case .listening: return .accentColor
        case .transcribing: return .blue
        case .inserted: return .green
        case .failed: return .red
        case .armed: return .accentColor
        }
    }
}

// MARK: - Level bar

/// A tiny level meter for the activity presentations. Purely presentational; the
/// level is the pure `DictationActivityState.level`.
private struct LevelBar: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(active ? Color.accentColor : Color.secondary)
                    .frame(width: max(4, CGFloat(min(1, max(0, level))) * geo.size.width))
            }
        }
    }
}
