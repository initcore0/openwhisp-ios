import SwiftUI
import SyncCore
import SyncKit

/// The WP7 "drive your Mac" surface, shown under a paired-device card in
/// ``YourMacView``. Four controls over the paired link (ARCHITECTURE §6.6):
///   (a) Remote dictate — capture on the Mac's mic, show the returned text;
///   (b) Answer a question — dictate with a prompt (the answer-by-voice path);
///   (c) Remote refine — text + instruction → refined text;
///   (d) Remote history — read-only browse of the Mac's recent transcriptions.
/// Every control surfaces consent-denied / rate-limited / Mac-busy / not-paired /
/// offline as an explicit inline state — never a silent no-op.
struct RemoteMacDriveView: View {
    let peer: PeerIdentity
    @EnvironmentObject private var remote: RemoteMacCoordinator
    @FocusState private var refineFocus: RefineField?

    private enum RefineField { case text, instruction }

    var body: some View {
        Group {
            dictateSection
            answerSection
            refineSection
            historySection
        }
    }

    // MARK: (a) Remote dictate

    private var dictateSection: some View {
        Section {
            Button {
                remote.dictate(peer)
            } label: {
                Label("Dictate on your Mac", systemImage: "mic.circle")
            }
            .disabled(remote.dictationPhase.isBusy)
            .accessibilityIdentifier("remoteDrive.dictate")

            dictationStateRow

            if remote.dictationPhase.isBusy {
                Button(role: .cancel) {
                    remote.stopDictation(peer)
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .accessibilityIdentifier("remoteDrive.stop")
            }
        } header: {
            Text("Remote dictate")
        } footer: {
            Text("Your Mac captures on its microphone and sends back the transcript. Speak at your Mac.")
        }
    }

    @ViewBuilder
    private var dictationStateRow: some View {
        switch remote.dictationPhase {
        case .idle:
            EmptyView()
        case .requesting:
            busyRow("Asking your Mac\u{2026}")
        case .listening:
            busyRow("Listening on your Mac\u{2026}", systemImage: "waveform")
                .accessibilityIdentifier("remoteDrive.listening")
        case .working:
            busyRow("Transcribing on your Mac\u{2026}")
        case .finished(let text):
            resultRow(text).accessibilityIdentifier("remoteDrive.dictateResult")
        case .failed(let error):
            errorRow(error).accessibilityIdentifier("remoteDrive.dictateError")
        }
    }

    // MARK: (b) Answer a question (dictate with a prompt)

    private var answerSection: some View {
        Section {
            Button {
                remote.dictate(peer, prompt: "Answer from your phone by voice.")
            } label: {
                Label("Answer a question by voice", systemImage: "bubble.left.and.mic")
            }
            .disabled(remote.dictationPhase.isBusy)
            .accessibilityIdentifier("remoteDrive.answer")
        } header: {
            Text("Answer your Mac")
        } footer: {
            Text("When an agent on your Mac asks a question, tap here to answer out loud \u{2014} "
                 + "your Mac shows the prompt and reads it aloud, and your spoken reply comes back. "
                 + "It's the same remote-dictate call, with the question as the prompt.")
        }
    }

    // MARK: (c) Remote refine

    private var refineSection: some View {
        Section {
            TextField("Text to refine", text: $refineText, axis: .vertical)
                .lineLimit(1...4)
                .focused($refineFocus, equals: .text)
                .toolbar {
                    // A multiline TextField has no return-to-dismiss; give the
                    // keyboard an explicit Done so it can always be closed.
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { refineFocus = nil }
                            .accessibilityIdentifier("remoteDrive.keyboardDone")
                    }
                }
                .accessibilityIdentifier("remoteDrive.refineText")
            TextField("Instruction (e.g. make it formal)", text: $refineInstruction)
                .focused($refineFocus, equals: .instruction)
                .submitLabel(.done)
                .onSubmit { refineFocus = nil }
                .accessibilityIdentifier("remoteDrive.refineInstruction")
            Button {
                refineFocus = nil
                remote.refine(peer, text: refineText, instruction: refineInstruction)
            } label: {
                if remote.isRefining {
                    HStack { ProgressView(); Text("Refining on your Mac\u{2026}") }
                } else {
                    Label("Refine on your Mac", systemImage: "wand.and.stars")
                }
            }
            .disabled(remote.isRefining || refineText.isEmpty)
            .accessibilityIdentifier("remoteDrive.refine")

            if let refined = remote.refinedText {
                resultRow(refined).accessibilityIdentifier("remoteDrive.refineResult")
            }
            if let error = remote.refineError {
                errorRow(error).accessibilityIdentifier("remoteDrive.refineError")
            }
        } header: {
            Text("Remote refine")
        } footer: {
            Text("Your Mac's LLM refines the text and sends it back. Nothing leaves your Mac unless it's configured for cloud AI.")
        }
    }

    // MARK: (d) Remote history browse

    private var historySection: some View {
        Section {
            Button {
                remote.loadHistory(peer)
            } label: {
                if remote.isLoadingHistory {
                    HStack { ProgressView(); Text("Loading\u{2026}") }
                } else {
                    Label("Browse your Mac's history", systemImage: "clock.arrow.circlepath")
                }
            }
            .disabled(remote.isLoadingHistory)
            .accessibilityIdentifier("remoteDrive.loadHistory")

            if let error = remote.historyError {
                errorRow(error).accessibilityIdentifier("remoteDrive.historyError")
            }

            ForEach(remote.history) { item in
                historyRow(item)
            }
        } header: {
            Text("Your Mac's recent history")
        } footer: {
            Text("Read-only. These stay on your Mac \u{2014} browsing doesn't copy them here.")
        }
    }

    private func historyRow(_ item: RemoteHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.text)
                .font(.callout)
                .lineLimit(3)
            HStack(spacing: 6) {
                if let label = item.appLabel {
                    Text(label)
                }
                if item.initiator == .agent {
                    Label("agent", systemImage: "cpu").labelStyle(.titleAndIcon)
                }
                Spacer()
                if let date = item.date {
                    Text(date, style: .relative)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reusable rows

    @State private var refineText = ""
    @State private var refineInstruction = ""

    private func busyRow(_ text: String, systemImage: String = "hourglass") -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Label(text, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func resultRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.body)
                .textSelection(.enabled)
            Text("From your Mac")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ error: RemoteMacError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName(for: error))
                .foregroundStyle(.orange)
            Text(error.userMessage)
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    private func iconName(for error: RemoteMacError) -> String {
        switch error {
        case .macBusy:               return "person.wave.2"
        case .rateLimited:           return "timer"
        case .consentDenied:         return "hand.raised"
        case .micPermissionNeeded:   return "mic.slash"
        case .secureField:           return "lock.shield"
        case .notPaired:             return "link.badge.plus"
        case .unreachable:           return "wifi.exclamationmark"
        default:                     return "exclamationmark.triangle"
        }
    }
}
