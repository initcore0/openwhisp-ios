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
                LabeledContent("Model", value: settings.activeModelID.rawValue)
                if !isActiveStaged {
                    if let p = progress {
                        ProgressView(value: p) { Text("Downloading… \(Int(p * 100))%") }
                    } else {
                        Button("Download active model") {
                            Task { await download(settings.activeModelID) }
                        }
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
                                Text(model.id.rawValue).font(.subheadline)
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
