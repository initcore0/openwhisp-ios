import SwiftUI
import MobileCore
import CaptureKit
import OpenWhispCore

/// Settings: engine + model variant picker, storage (model sizes / delete),
/// language hint, privacy screen, and the Developer section → Engine Lab.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        NavigationStack {
            Form {
                engineSection
                languageSection
                sessionSection

                Section {
                    NavigationLink {
                        DictationSetupView()
                    } label: {
                        Label("Dictation Shortcuts", systemImage: "bolt.circle")
                    }
                    .accessibilityIdentifier("settings.dictationSetup")
                } header: {
                    Text("Hands-free dictation")
                } footer: {
                    Text("Set the Action button or a Control Center control to start OpenWhisp "
                         + "dictation without opening the app.")
                }

                Section {
                    NavigationLink {
                        YourMacView()
                    } label: {
                        Label("Your Mac", systemImage: "laptopcomputer.and.iphone")
                    }
                    .accessibilityIdentifier("settings.yourMac")
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Pair your Mac to keep your vocabulary, history, and profiles in step "
                         + "over your local Wi-Fi. Nothing goes to the cloud.")
                }

                Section {
                    NavigationLink {
                        ModelStorageView()
                    } label: {
                        Label("Models & Storage", systemImage: "internaldrive")
                    }
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Label("Privacy", systemImage: "lock.shield")
                    }
                }

                Section {
                    NavigationLink {
                        EngineLabView()
                    } label: {
                        Label("Engine Lab", systemImage: "flask")
                    }
                    .accessibilityIdentifier("settings.engineLab")
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Benchmark OpenWhisp's engines against Apple's built-in recognizer "
                         + "on the same audio — the proof that on-device beats Apple, "
                         + "especially multilingual.")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var engineSection: some View {
        Section("Engine") {
            Picker("Engine", selection: $settings.engineFamily) {
                ForEach(EngineFamily.allCases) { Text($0.title).tag($0) }
            }
            switch settings.engineFamily {
            case .parakeet:
                Picker("Variant", selection: $settings.parakeetVariant) {
                    ForEach(ParakeetCatalog.variants, id: \.id) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                Text(ParakeetCatalog.variant(for: settings.parakeetVariant).detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .whisperKit:
                Picker("Model", selection: $settings.whisperModel) {
                    ForEach(WhisperKitModelCatalog.selectableModels(), id: \.self) { m in
                        Text(WhisperKitModelCatalog.displayInfo(for: m).label).tag(m)
                    }
                }
                if let hint = WhisperKitModelCatalog.displayInfo(for: settings.whisperModel).hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Dictation Sessions (WP10b): the idle-timeout picker + the mic-privacy copy.
    private var sessionSection: some View {
        Section {
            Picker("Idle timeout", selection: $settings.sessionIdleTimeout) {
                ForEach(DictationSessionConfig.IdleTimeout.allCases, id: \.self) { t in
                    Text(Self.timeoutLabel(t)).tag(t)
                }
            }
            .accessibilityIdentifier("settings.sessionTimeout")
        } header: {
            Text("Dictation Sessions")
        } footer: {
            Text("Tap the keyboard's mic key to arm a session once, then dictate "
                 + "instantly from any app without switching back. An idle session "
                 + "ends itself after this long. The mic stays available while a "
                 + "session is on \u{2014} iOS shows the orange indicator the whole time.")
        }
    }

    private static func timeoutLabel(_ t: DictationSessionConfig.IdleTimeout) -> String {
        switch t {
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        case .never: return "Never (end manually)"
        }
    }

    private var languageSection: some View {
        Section {
            Picker("Language hint", selection: $settings.languageHint) {
                ForEach(AppSettings.languageChoices, id: \.code) { choice in
                    Text(choice.label).tag(choice.code)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Auto-detect works best with the multilingual Parakeet variant. Pinning "
                 + "a language can improve accuracy when you know what you'll speak.")
        }
    }
}

// MARK: - Models & storage

struct ModelStorageView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var staged: [StagedModel] = []
    @State private var downloadTarget: ModelID?
    @State private var progress: Double?
    @State private var errorText: String?

    private let provisioning = IOSModelProvisioning()

    var body: some View {
        Form {
            Section("Active model") {
                LabeledContent("Engine", value: settings.engineFamily.title)
                LabeledContent("Model", value: ModelDisplay.name(for: settings.activeModelID))
                if isActiveStaged {
                    Label("Downloaded and ready", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else if let p = progress {
                    ModelDownloadRow(model: settings.activeModelID, fraction: p)
                } else {
                    Button("Download active model") {
                        Task { await download(settings.activeModelID) }
                    }
                }
                if let e = errorText {
                    Text(e).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                if staged.isEmpty {
                    Text("No models downloaded yet. Models download on first use, or from "
                         + "the button above.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    ForEach(staged, id: \.id.rawValue) { model in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ModelDisplay.name(for: model.id)).font(.subheadline)
                                Text(Self.sizeString(model.sizeBytes))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                delete(model.id)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            } header: {
                Text("Downloaded models")
            } footer: {
                Text("Models are stored only in this app. Deleting one frees space; it "
                     + "re-downloads the next time you select it.")
            }
        }
        .navigationTitle("Models & Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    private var isActiveStaged: Bool {
        staged.contains { $0.id == settings.activeModelID }
    }

    private func refresh() {
        staged = provisioning.staged
    }

    private func download(_ id: ModelID) async {
        errorText = nil
        progress = 0
        downloadTarget = id
        do {
            try await provisioning.download(id) { fraction in
                Task { @MainActor in progress = fraction }
            }
            progress = nil
            refresh()
        } catch {
            errorText = error.localizedDescription
            progress = nil
        }
    }

    private func delete(_ id: ModelID) {
        try? provisioning.delete(id)
        refresh()
    }

    static func sizeString(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "size unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Dictation setup walkthrough (hero surfaces, ARCHITECTURE §5.1)

/// Guides the user to wire the sanctioned no-app-switch dictation triggers: the
/// Action button and a Control Center control, both of which launch
/// `StartDictationIntent`. Pure guidance — iOS provides no API to set the Action
/// button programmatically, so this is a walkthrough, not a one-tap toggle.
struct DictationSetupView: View {
    var body: some View {
        Form {
            Section {
                Label("Dictate without opening OpenWhisp", systemImage: "bolt.circle.fill")
                    .font(.headline)
                Text("Assign the Action button or a Control Center control to OpenWhisp "
                     + "Dictation. Press it in any app, speak, and your text is handed to "
                     + "the keyboard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Action button (iPhone 15 Pro and later)") {
                step(1, "Open Settings \u{2192} Action Button.")
                step(2, "Swipe to Shortcut, then tap Choose a Shortcut.")
                step(3, "Pick Start OpenWhisp Dictation.")
            }

            Section("Control Center") {
                step(1, "Swipe down from the top-right to open Control Center.")
                step(2, "Tap +, then Add a Control.")
                step(3, "Choose OpenWhisp Dictation.")
            }

            Section {
                Text("Whichever you use, dictation starts on-device and inserts through the "
                     + "keyboard. If a hands-free start isn't permitted from your current app, "
                     + "OpenWhisp opens to finish the dictation, then you switch back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Good to know")
            }
        }
        .navigationTitle("Dictation Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("dictationSetup.root")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            Text(text).font(.subheadline)
        }
    }
}

// MARK: - Privacy (static copy per ARCHITECTURE §7)

struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                Label("Your audio and text never leave this device.", systemImage: "iphone")
                    .font(.headline)
            }
            Section("What OpenWhisp does") {
                bullet("Transcription runs entirely on-device (Parakeet / WhisperKit on the Neural Engine).")
                bullet("No analytics, no crash SDKs, no third-party SDKs at all.")
                bullet("Privacy nutrition label: Data not collected.")
            }
            Section("The only network request") {
                bullet("One-time model downloads from the model CDN, user-initiated and shown with progress.")
                bullet("Optional sync to your paired Mac happens over your local Wi-Fi (TLS), never the cloud.")
            }
            Section("Secure fields") {
                bullet("The keyboard refuses to insert into password fields, and can't dictate there at all.")
            }
            Section("Dictation Sessions") {
                bullet("While a session is on, the mic stays available so you can dictate "
                       + "instantly \u{2014} iOS shows the orange indicator the whole time. End "
                       + "the session anytime, and it ends itself after the idle timeout.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bullet(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
    }
}
