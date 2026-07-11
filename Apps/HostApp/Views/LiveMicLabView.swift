import SwiftUI
import Combine
import MobileCore

/// Live-mic Engine Lab mode: dictate a real utterance through the active engine and
/// see the transcript + latency / RTF / RSS. No reference (WER n/a); this is the
/// "how does it feel on my voice" instrument.
struct LiveMicLabView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var labRuns: LabRunStore
    @StateObject private var holder = LiveMicHolder()

    var body: some View {
        Group {
            if let vm = holder.vm {
                content(vm)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Live-mic run")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { holder.configure(settings: settings, store: labRuns) }
    }

    @ViewBuilder
    private func content(_ vm: LiveMicLabViewModel) -> some View {
        VStack(spacing: 20) {
            Text("Engine: \(settings.engineFamily.title)")
                .font(.subheadline).foregroundStyle(.secondary)

            Waveform(levels: vm.levels, active: vm.phase == .listening)
                .padding(.horizontal)

            if !vm.partial.isEmpty && vm.transcript.isEmpty {
                Text(vm.partial).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if !vm.transcript.isEmpty {
                ScrollView {
                    Text(vm.transcript).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(.horizontal)
            }
            if let run = vm.lastRun {
                HStack {
                    metric("Latency", String(format: "%.2fs", run.metrics.latencySeconds))
                    metric("Δ RSS", run.metrics.peakRSSDeltaString)
                }
                .padding(.horizontal)
            }
            if case .failed(let m) = vm.phase {
                Text(m).font(.footnote).foregroundStyle(.red)
            }

            Spacer()
            Button {
                vm.toggle()
            } label: {
                ZStack {
                    Circle().fill(vm.isBusy ? Color.red : Color.accentColor)
                        .frame(width: 76, height: 76)
                    Image(systemName: vm.isBusy ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .padding(.top)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.headline)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
final class LiveMicHolder: ObservableObject {
    @Published private(set) var vm: LiveMicLabViewModel?
    private var configured = false
    private var cancellable: AnyObject?

    func configure(settings: AppSettings, store: LabRunStore) {
        guard !configured else { return }
        configured = true
        let vm = LiveMicLabViewModel(settings: settings, store: store)
        self.cancellable = vm.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        } as AnyObject
        self.vm = vm
    }
}
