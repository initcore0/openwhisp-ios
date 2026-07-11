import SwiftUI
import Combine
import UniformTypeIdentifiers
import MobileCore
import CaptureKit
import OpenWhispCore

/// The Engine Lab (WP3) — the product's Goal-#1 instrument. Lists the bundled
/// fixtures, runs a selected fixture through any installed engine (Parakeet /
/// WhisperKit / Apple baseline) via the `FileTranscriptionEngine` seam, shows the
/// transcript vs. reference with word-level diff + WER, latency / realtime factor /
/// peak-RSS delta, a side-by-side compare-vs-Apple verdict, a live-mic mode, and the
/// persisted run log with JSON export.
struct EngineLabView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var labRuns: LabRunStore
    @StateObject private var holder = EngineLabHolder()

    var body: some View {
        Group {
            if let vm = holder.vm {
                content(vm)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Engine Lab")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { holder.configure(settings: settings, store: labRuns) }
    }

    @ViewBuilder
    private func content(_ vm: EngineLabViewModel) -> some View {
        Form {
            if !vm.fixturesAvailable {
                Section {
                    ContentUnavailableView(
                        "No fixtures bundled",
                        systemImage: "waveform.slash",
                        description: Text("Benchmark fixtures are bundled in Debug builds only "
                                          + "(to keep release size down). Run a Debug build to use "
                                          + "the fixture lab.")
                    )
                }
            }

            EngineLabActiveEngineSection()

            if vm.fixturesAvailable {
                fixtureSection(vm)
            }

            if let run = vm.lastRun {
                resultSection(run: run, diff: vm.lastDiff)
            }

            if let verdict = vm.compareVerdict {
                verdictSection(verdict: verdict, ow: vm.compareOpenWhisp, apple: vm.compareApple)
            }

            Section {
                NavigationLink {
                    LiveMicLabView()
                } label: { Label("Live-mic run", systemImage: "mic.circle") }
            }

            runLogSection()
        }
        .disabled(vm.isRunning)
        .overlay {
            if vm.isRunning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(vm.status).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    // MARK: - Sections

    private func fixtureSection(_ vm: EngineLabViewModel) -> some View {
        Section("Fixtures") {
            ForEach(vm.fixtures) { bundled in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(bundled.fixture.title).font(.subheadline.bold())
                            Text(bundled.reference.isEmpty ? "(silence — expects no words)" : bundled.reference)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        if !bundled.fixture.language.isEmpty {
                            Text(bundled.fixture.language.uppercased())
                                .font(.caption2.bold())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    HStack {
                        Button("Run") { Task { await vm.run(bundled) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Compare vs Apple") { Task { await vm.compare(bundled) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.purple)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func resultSection(run: LabRun, diff: WERResult?) -> some View {
        Section("Latest run — \(run.engineName)") {
            metricRow(run: run)
            if let error = run.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcript").font(.caption).foregroundStyle(.secondary)
                    Text(run.hypothesis.isEmpty ? "(no output)" : run.hypothesis)
                        .font(.callout)
                        .textSelection(.enabled)
                    if let diff, !diff.tokens.isEmpty {
                        Divider()
                        Text("Diff vs reference (WER \(diff.werPercentString))")
                            .font(.caption).foregroundStyle(.secondary)
                        DiffView(result: diff)
                    }
                }
            }
        }
    }

    private func metricRow(run: LabRun) -> some View {
        HStack {
            metric("WER", run.werPercentString, tint: werTint(run.wer))
            Divider().frame(height: 28)
            metric("Latency", String(format: "%.2fs", run.metrics.latencySeconds))
            Divider().frame(height: 28)
            metric("RTF", run.metrics.realtimeFactorString)
            Divider().frame(height: 28)
            metric("Δ RSS", run.metrics.peakRSSDeltaString)
        }
    }

    private func metric(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func verdictSection(verdict: LabVerdict, ow: LabRun?, apple: LabRun?) -> some View {
        Section("Verdict") {
            Text(verdict.summary)
                .font(.callout.bold())
                .foregroundStyle(verdictColor(verdict.winner))
                .accessibilityIdentifier("lab.verdict")
            if let ow {
                LabeledContent("OpenWhisp", value: "\(ow.werPercentString) · \(ow.metrics.realtimeFactorString)")
            }
            if let apple {
                LabeledContent("Apple baseline",
                               value: apple.error == nil ? apple.werPercentString : "unavailable")
                if let e = apple.error {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runLogSection() -> some View {
        Section("Saved runs (\(labRuns.runs.count))") {
            if labRuns.runs.isEmpty {
                Text("Runs are saved here and can be exported as JSON.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(labRuns.runs.prefix(8)) { run in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(run.engineName)").font(.caption.bold())
                            Text("\(run.fixtureName.isEmpty ? "live" : run.fixtureName) · \(run.werPercentString)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(run.date, format: .dateTime.hour().minute())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let data = labRuns.exportData() {
                    ShareLink(
                        item: LabExportFile(data: data),
                        preview: SharePreview("lab-runs.json")
                    ) {
                        Label("Export runs (JSON)", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Clear saved runs", role: .destructive) { labRuns.clear() }
            }
        }
    }

    // MARK: - Colors

    private func werTint(_ wer: Double?) -> Color {
        guard let wer else { return .secondary }
        if wer < 0.05 { return .green }
        if wer < 0.15 { return .yellow }
        return .red
    }

    private func verdictColor(_ winner: LabVerdict.Winner) -> Color {
        switch winner {
        case .openWhisp, .baselineUnavailable: return .green
        case .apple: return .red
        case .tie: return .secondary
        }
    }
}

/// Shows the currently-selected engine (from Settings) so the Lab is honest about
/// what "Run" uses.
struct EngineLabActiveEngineSection: View {
    @EnvironmentObject private var settings: AppSettings
    var body: some View {
        Section("Active OpenWhisp engine") {
            LabeledContent("Engine", value: settings.engineFamily.title)
            LabeledContent("Model", value: settings.activeModelID.rawValue)
            Text("Change the engine/model in Settings; the Lab runs whatever is active. "
                 + "Compare mode always pits it against Apple's on-device baseline.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Word-level diff rendering: equal words plain, substitutions/insertions/deletions
/// color-highlighted so a human sees exactly what each engine got wrong.
struct DiffView: View {
    let result: WERResult

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(result.tokens) { token in
                chip(for: token)
            }
        }
    }

    @ViewBuilder
    private func chip(for token: DiffToken) -> some View {
        switch token.op {
        case .equal:
            Text(token.hypothesis ?? "")
                .font(.callout)
        case .substitute:
            Text(token.hypothesis ?? "")
                .font(.callout)
                .padding(.horizontal, 3)
                .background(.orange.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                .strikethrough(false)
                .help("expected: \(token.reference ?? "")")
        case .insert:
            Text(token.hypothesis ?? "")
                .font(.callout)
                .padding(.horizontal, 3)
                .background(.red.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
        case .delete:
            Text(token.reference ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .strikethrough()
                .padding(.horizontal, 3)
                .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// A file wrapper so ShareLink can export the runs JSON.
struct LabExportFile: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("lab-runs.json")
    }
}

@MainActor
final class EngineLabHolder: ObservableObject {
    @Published private(set) var vm: EngineLabViewModel?
    private var configured = false
    private var cancellable: AnyObject?

    func configure(settings: AppSettings, store: LabRunStore) {
        guard !configured else { return }
        configured = true
        let vm = EngineLabViewModel(settings: settings, store: store)
        self.cancellable = vm.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        } as AnyObject
        self.vm = vm
    }
}
