import SwiftUI
import Combine

/// The in-app dictation composer (ARCHITECTURE §5, flow #3): a big record button
/// driving `CaptureCoordinating`, a live level waveform + streaming partials, and
/// the final CLEANED text in an editable field with copy + share. Finished text is
/// auto-appended to history by the view model.
struct DictateView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var router: DictationRouter
    @StateObject private var vm: CaptureViewModelHolder = CaptureViewModelHolder()
    @State private var showCopied = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let model = vm.model {
                    composer(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Dictate")
            .onAppear { vm.configure(settings: settings, history: history) }
        }
    }

    @ViewBuilder
    private func composer(_ model: CaptureViewModel) -> some View {
        VStack(spacing: 20) {
            statusRow(model)

            Waveform(levels: model.levels, active: model.phase == .listening)
                .padding(.horizontal)

            if !model.partial.isEmpty && model.finalText.isEmpty {
                ScrollView {
                    Text(model.partial)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(.horizontal)
            }

            editor(model)

            if let error = errorText(model) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
            recordButton(model)
            dictateForAnotherAppButton(model)
        }
        .padding(.top)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    copy(model)
                } label: { Image(systemName: "doc.on.doc") }
                    .disabled(model.finalText.isEmpty)
                    .accessibilityIdentifier("composer.copy")

                ShareLink(item: model.finalText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.finalText.isEmpty)
                .accessibilityIdentifier("composer.share")
            }

            // The editor is inside a plain VStack (no scroll view), so without an
            // explicit affordance the system keyboard has no way to be dismissed.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editorFocused = false }
                    .accessibilityIdentifier("composer.keyboardDone")
            }
        }
        .overlay(alignment: .bottom) {
            if showCopied {
                Text("Copied")
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 92)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Pieces

    private func statusRow(_ model: CaptureViewModel) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(model))
                    .frame(width: 10, height: 10)
                Text(statusLabel(model))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("composer.status")
            }
            // First-use honesty: "Preparing…" can include staging the model — a
            // large download — and without saying so the app looks hung for minutes.
            if model.phase == .preparing && model.isFirstUseDownload {
                Text("Downloading the speech model for first use — a few minutes on "
                     + "Wi-Fi, one time only. You can also download it up front in "
                     + "Settings → Models & Storage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("composer.firstUseDownload")
            }
        }
    }

    private func editor(_ model: CaptureViewModel) -> some View {
        TextEditor(text: Binding(
            get: { model.finalText },
            set: { model.finalText = $0 }
        ))
        .focused($editorFocused)
        .font(.body)
        .frame(minHeight: 160)
        .overlay(alignment: .topLeading) {
            if model.finalText.isEmpty {
                Text("Your dictation will appear here — editable.")
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8).padding(.leading, 5)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal)
        .accessibilityIdentifier("composer.editor")
    }

    private func recordButton(_ model: CaptureViewModel) -> some View {
        Button {
            editorFocused = false
            model.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(model.isBusy ? Color.red : Color.accentColor)
                    .frame(width: 84, height: 84)
                Image(systemName: model.isBusy ? "stop.fill" : "mic.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 24)
        .accessibilityLabel(model.isBusy ? "Stop" : "Record")
        .accessibilityIdentifier("composer.record")
    }

    /// Opens the compact dictation SHEET that publishes to the App Group so the
    /// keyboard can insert the result into whatever app you switch to next
    /// (ARCHITECTURE §5.2 floor flow). Distinct from the composer's own record
    /// button, which keeps the text in-app. Hidden while an in-app capture is busy.
    @ViewBuilder
    private func dictateForAnotherAppButton(_ model: CaptureViewModel) -> some View {
        Button {
            router.present(trigger: .keyboardHandoff)
        } label: {
            Label("Dictate for another app", systemImage: "keyboard.badge.ellipsis")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .disabled(model.isBusy)
        .padding(.bottom, 16)
        .accessibilityIdentifier("composer.dictateForAnotherApp")
    }

    private func statusColor(_ model: CaptureViewModel) -> Color {
        switch model.phase {
        case .idle: return .secondary
        case .preparing: return .yellow
        case .listening: return .green
        case .transcribing: return .blue
        case .failed: return .red
        }
    }

    private func statusLabel(_ model: CaptureViewModel) -> String {
        switch model.phase {
        case .idle: return model.finalText.isEmpty ? "Ready" : "Done"
        case .preparing: return "Preparing…"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .failed: return "Error"
        }
    }

    private func errorText(_ model: CaptureViewModel) -> String? {
        if case .failed(let m) = model.phase { return m }
        return nil
    }

    private func copy(_ model: CaptureViewModel) {
        UIPasteboard.general.string = model.finalText
        withAnimation { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showCopied = false }
        }
    }
}

/// Holds the `CaptureViewModel` so the SwiftUI view can lazily configure it with
/// environment stores on appear (view models can't read `@EnvironmentObject` at
/// `@StateObject` init time). Re-publishes the model's changes.
@MainActor
final class CaptureViewModelHolder: ObservableObject {
    // @Published so assigning the model on `configure` swaps ProgressView → the
    // composer on the next render.
    @Published private(set) var model: CaptureViewModel?
    private var configured = false
    private var cancellable: AnyObject?

    func configure(settings: AppSettings, history: HistoryStore) {
        guard !configured else { return }
        configured = true
        let m = CaptureViewModel(settings: settings, history: history)
        // Bridge the inner ObservableObject's changes to this holder so the view
        // re-renders when capture state advances.
        self.cancellable = m.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        } as AnyObject
        self.model = m
    }
}
