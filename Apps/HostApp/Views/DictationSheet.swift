import SwiftUI
import MobileCore

/// The compact DICTATION SHEET (ARCHITECTURE §5.2 floor flow). Presented when the
/// app is opened on `openwhisp://dictate`, or from the composer's "Dictate for
/// another app" affordance. Deliberately NOT the full composer: a big waveform, a
/// listening state, and — on publish — a "return to your app" hint, because there
/// is no supported API to switch back to the user's previous app [C9]; the keyboard
/// inserts the pending transcript on its next appearance.
struct DictationSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @Environment(\.dismiss) private var dismiss

    /// How the capture was triggered — stamps the transcript's source and the Live
    /// Activity. Floor flow passes `.keyboardHandoff`; the composer affordance too.
    let trigger: CaptureTrigger

    @StateObject private var holder = HandoffDictationHolder()
    @State private var dismissWork: DispatchWorkItem?

    var body: some View {
        Group {
            if let model = holder.model {
                content(model)
            } else {
                ProgressView().onAppear {
                    holder.configure(settings: settings, history: history, trigger: trigger)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(false)
    }

    @ViewBuilder
    private func content(_ model: HandoffDictationViewModel) -> some View {
        VStack(spacing: 24) {
            header(model)

            Waveform(levels: model.levels, active: model.phase == .listening)
                .frame(height: 72)
                .padding(.horizontal, 24)

            if !model.partial.isEmpty, publishedText(model) == nil {
                Text(model.partial)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("sheet.partial")
            }

            if let text = publishedText(model) {
                publishedBanner(text)
            } else if case .failed(let message) = model.phase {
                failureView(message)
            }

            Spacer()
            controls(model)
        }
        .padding(.top, 28)
        .onAppear { model.begin() }
        .onChange(of: model.phase) { _, phase in
            if case .published = phase { scheduleAutoDismiss() }
        }
        .onDisappear {
            dismissWork?.cancel()
            // Leaving the sheet while still live cancels the capture (nothing to
            // hand off from a half-finished dictation).
            if model.isBusy { model.cancel() }
        }
    }

    // MARK: - Pieces

    private func header(_ model: HandoffDictationViewModel) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol(model))
                .font(.system(size: 34))
                .foregroundStyle(tint(model))
                .accessibilityHidden(true)
            Text(statusLabel(model))
                .font(.headline)
                .accessibilityIdentifier("sheet.status")
        }
    }

    private func publishedBanner(_ text: String) -> some View {
        VStack(spacing: 10) {
            Label("Ready to insert", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityIdentifier("sheet.published")
            Text("Return to your app — your text will appear automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("sheet.publishedText")
            }
        }
    }

    private func failureView(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .accessibilityIdentifier("sheet.error")
    }

    @ViewBuilder
    private func controls(_ model: HandoffDictationViewModel) -> some View {
        if publishedText(model) != nil {
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 28)
                .accessibilityIdentifier("sheet.done")
        } else if case .failed = model.phase {
            Button("Close") { dismiss() }
                .buttonStyle(.bordered)
                .padding(.bottom, 28)
                .accessibilityIdentifier("sheet.close")
        } else {
            Button {
                model.stop()
            } label: {
                ZStack {
                    Circle().fill(Color.red).frame(width: 76, height: 76)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 28)
            .accessibilityLabel("Stop")
            .accessibilityIdentifier("sheet.stop")
        }
    }

    // MARK: - Derivations

    private func publishedText(_ model: HandoffDictationViewModel) -> String? {
        model.publishedText
    }

    private func symbol(_ model: HandoffDictationViewModel) -> String {
        switch model.phase {
        case .idle, .preparing: return "mic"
        case .listening: return "waveform"
        case .transcribing: return "ellipsis"
        case .published: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ model: HandoffDictationViewModel) -> Color {
        switch model.phase {
        case .idle, .preparing: return .secondary
        case .listening: return .accentColor
        case .transcribing: return .blue
        case .published: return .green
        case .failed: return .red
        }
    }

    private func statusLabel(_ model: HandoffDictationViewModel) -> String {
        switch model.phase {
        case .idle: return "Starting\u{2026}"
        case .preparing: return "Preparing\u{2026}"
        case .listening: return "Listening\u{2026}"
        case .transcribing: return "Transcribing\u{2026}"
        case .published: return "Done"
        case .failed: return "Couldn't dictate"
        }
    }

    private func scheduleAutoDismiss() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { dismiss() }
        dismissWork = work
        // A beat so the user reads the "return to your app" hint before it closes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

/// Holds the `HandoffDictationViewModel` so the SwiftUI sheet can lazily configure
/// it with environment stores on appear (view models can't read
/// `@EnvironmentObject` at `@StateObject` init time). Mirrors the composer's
/// `CaptureViewModelHolder` pattern.
@MainActor
final class HandoffDictationHolder: ObservableObject {
    @Published private(set) var model: HandoffDictationViewModel?
    private var configured = false
    private var cancellable: AnyObject?

    func configure(settings: AppSettings, history: HistoryStore, trigger: CaptureTrigger) {
        guard !configured else { return }
        configured = true
        let m = HandoffDictationViewModel(settings: settings, history: history, trigger: trigger)
        self.cancellable = m.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        } as AnyObject
        self.model = m
    }
}
