import SwiftUI
import MobileCore
import CaptureKit
import OpenWhispCore

/// First-launch onboarding (WP3): the privacy pitch + mic permission, then an
/// engine/model choice (the RAM-based recommended default preselected), then an
/// optional model download with progress. Skippable at every step — the app is
/// usable without downloading anything up front (the engine self-stages on first
/// dictation).
struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var step: Step = .welcome
    @State private var micGranted: Bool?
    @State private var downloadProgress: Double?
    @State private var downloadError: String?
    @State private var downloadedOK = false

    private let provisioning = IOSModelProvisioning()

    enum Step: Int { case welcome, engine, model }

    var body: some View {
        NavigationStack {
            VStack {
                switch step {
                case .welcome: welcome
                case .engine: enginePick
                case .model: modelStep
                }
            }
            .padding()
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { finish() }
                        .accessibilityIdentifier("onboarding.skip")
                }
            }
        }
        .onAppear(perform: preselectRecommended)
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Local-first dictation")
                .font(.largeTitle.bold())
            Text("OpenWhisp transcribes your speech entirely on your iPhone. "
                 + "Your audio and text never leave the device — no cloud, no account, "
                 + "no analytics.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Label("Microphone is used only to transcribe, on-device.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await requestMicThenAdvance() }
            } label: {
                Text(micGranted == false ? "Continue anyway" : "Allow microphone & continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboarding.allowMic")

            if micGranted == false {
                Text("Microphone access was declined. You can enable it later in Settings; "
                     + "the rest of the app still works.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var enginePick: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your engine")
                .font(.title2.bold())
            Text("The recommended default is preselected for your device. You can "
                 + "change this anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(EngineFamily.allCases) { family in
                Button {
                    settings.engineFamily = family
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: settings.engineFamily == family ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(family.title).font(.headline)
                            Text(family.blurb).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }

            Spacer()
            Button("Continue") { step = .model }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download the model?")
                .font(.title2.bold())
            Text("The transcription model runs on-device and is a large one-time "
                 + "download (hundreds of MB — best on Wi-Fi). Downloading it now is "
                 + "strongly recommended: if you skip, your FIRST dictation will sit "
                 + "on \u{201C}Preparing\u{2026}\u{201D} while it downloads. This is the only network "
                 + "request OpenWhisp ever makes.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            LabeledContent("Engine", value: settings.engineFamily.title)
            LabeledContent("Model", value: ModelDisplay.name(for: settings.activeModelID))

            if let p = downloadProgress {
                ModelDownloadRow(model: settings.activeModelID, fraction: p)
            }
            if let e = downloadError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
            if downloadedOK {
                Label("Model ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            Spacer()
            VStack(spacing: 12) {
                Button {
                    Task { await download() }
                } label: {
                    Text("Download now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(downloadProgress != nil)

                Button("Do it later") { finish() }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func preselectRecommended() {
        settings.applyRecommendedDefaults(provisioning: provisioning, deviceClass: Self.deviceClass())
    }

    private func requestMicThenAdvance() async {
        let granted = await CaptureViewModel.requestMicPermission()
        micGranted = granted
        step = .engine
    }

    private func download() async {
        downloadError = nil
        downloadProgress = 0
        do {
            try await provisioning.download(settings.activeModelID) { fraction in
                Task { @MainActor in downloadProgress = fraction }
            }
            downloadedOK = true
            downloadProgress = nil
            finish()
        } catch {
            downloadError = error.localizedDescription
            downloadProgress = nil
        }
    }

    private func finish() {
        settings.didOnboard = true
    }

    /// Rough device RAM class from physical memory (the provisioning heuristic input).
    static func deviceClass() -> DeviceClass {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        if gb <= 4 { return .low }
        if gb <= 6 { return .mid }
        return .high
    }
}
