import Foundation
import Combine
import OpenWhispCore
import SyncCore
import SyncKit

/// The host-app front end for DRIVING a paired Mac's tools (WP7, ARCHITECTURE
/// §6.6): remote dictate, remote refine, remote history browse, and the
/// answer-a-question-by-voice affordance. It REUSES the same pairing (Keychain +
/// PSK) and Bonjour/TLS transport the ``SyncCoordinator`` uses — a
/// ``RemoteMacClient`` whose session comes from `transport.connect(to:psk:...)`,
/// the identical path the sync engine takes — so no PSK/Keychain logic is
/// duplicated here.
///
/// Foreground-only, like sync: every drive call opens a fresh TLS-PSK session,
/// runs off the main actor, and closes it. iOS tears down the socket within ~30s
/// of backgrounding, so these controls are meant to be used while the app is
/// open. Failures are surfaced as explicit UI states (never silent) AND logged to
/// a small journal, matching the sync coordinator's fail-to-journal posture.
@MainActor
final class RemoteMacCoordinator: ObservableObject {
    // Remote dictate / answer-a-question.
    @Published private(set) var dictationPhase: RemoteDictationPhase = .idle
    @Published private(set) var lastDictationText: String?

    // Remote refine.
    @Published private(set) var isRefining = false
    @Published private(set) var refinedText: String?
    @Published private(set) var refineError: RemoteMacError?

    // Remote history browse.
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var history: [RemoteHistoryItem] = []
    @Published private(set) var historyError: RemoteMacError?

    // Status probe (reachability + capability disclosure).
    @Published private(set) var isProbing = false
    @Published private(set) var status: BridgeWire.StatusResult?
    @Published private(set) var statusError: RemoteMacError?

    /// A small journal shared with the drive surface (mirrors the sync journal).
    @Published private(set) var journal: [JournalEntry] = []

    struct JournalEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let message: String
    }

    private let pairing: PairingService
    private let transport: PeerTransport
    private let clientName: String

    /// Test seam: inject a client factory so unit tests drive a fake session
    /// without pairing/transport. Production leaves it nil and builds the real
    /// client from `pairing` + `transport`.
    private let clientOverride: ((PeerIdentity) -> RemoteMacClient?)?

    init(
        pairing: PairingService? = nil,
        transport: PeerTransport = BonjourPeerTransport(),
        clientName: String = "iPhone",
        clientFactory: ((PeerIdentity) -> RemoteMacClient?)? = nil
    ) {
        self.pairing = pairing ?? DefaultPairingService(secrets: KeychainSecretStore())
        self.transport = transport
        self.clientName = clientName
        self.clientOverride = clientFactory
    }

    // MARK: - Client construction (reuses pairing PSK + transport)

    /// Build a ``RemoteMacClient`` for `peer`, whose session provider dials the
    /// SAME Bonjour/TLS transport with the SAME Keychain PSK the sync engine uses.
    /// Returns nil (→ `.notPaired`) when no key is stored.
    private func makeClient(for peer: PeerIdentity) -> RemoteMacClient? {
        if let clientOverride { return clientOverride(peer) }
        guard let psk = pairing.psk(for: peer.id) else { return nil }
        let transport = self.transport
        let clientName = self.clientName
        return RemoteMacClient(sessionProvider: {
            try transport.connect(to: peer, psk: psk, clientName: clientName)
        })
    }

    // MARK: - Status probe

    func probeStatus(_ peer: PeerIdentity) {
        guard !isProbing else { return }
        isProbing = true
        statusError = nil
        runClient(for: peer,
                  onMissing: { self.isProbing = false; self.statusError = .notPaired },
                  work: { try $0.remoteStatus() },
                  done: { result in
                      self.isProbing = false
                      switch result {
                      case .success(let s):
                          self.status = s
                          self.log("Status: \(s.engine) \u{2014} session \(s.sessionActive ? "active" : "idle").")
                      case .failure(let e):
                          self.statusError = e
                          self.log("Status failed: \(e.userMessage)")
                      }
                  })
    }

    // MARK: - Remote dictate / answer-a-question

    /// Ask the Mac to capture on its mic and return the transcript. With `prompt`
    /// the Mac shows its agent-question overlay + TTS — the returned text is the
    /// human's spoken answer (the answer-a-question-by-voice path).
    func dictate(_ peer: PeerIdentity, prompt: String? = nil, timeoutSeconds: Int? = nil) {
        guard !dictationPhase.isBusy else { return }
        dictationPhase = .requesting
        lastDictationText = nil
        runClient(for: peer,
                  onMissing: { self.dictationPhase = .failed(.notPaired) },
                  work: { try $0.remoteDictate(prompt: prompt, timeoutSeconds: timeoutSeconds) },
                  done: { result in
                      switch result {
                      case .success(let r):
                          self.lastDictationText = r.text
                          self.dictationPhase = .finished(text: r.text)
                          self.log("Dictated on your Mac (\(r.endedBy.rawValue)): \(Self.snippet(r.text)).")
                      case .failure(let e):
                          self.dictationPhase = .failed(e)
                          self.log("Remote dictate failed: \(e.userMessage)")
                      }
                  })
    }

    /// Stop an in-flight remote dictation; the blocking `dictate` call returns
    /// with what the Mac has. Best-effort — opens its own short session.
    func stopDictation(_ peer: PeerIdentity) {
        runClient(for: peer,
                  onMissing: { },
                  work: { try $0.remoteStopDictation() },
                  done: { _ in self.log("Asked your Mac to stop dictating.") })
    }

    func resetDictation() {
        dictationPhase = .idle
        lastDictationText = nil
    }

    // MARK: - Remote refine

    func refine(_ peer: PeerIdentity, text: String, instruction: String) {
        guard !isRefining, !text.isEmpty else { return }
        isRefining = true
        refineError = nil
        refinedText = nil
        runClient(for: peer,
                  onMissing: { self.isRefining = false; self.refineError = .notPaired },
                  work: { try $0.remoteRefine(text: text, instruction: instruction) },
                  done: { result in
                      self.isRefining = false
                      switch result {
                      case .success(let r):
                          self.refinedText = r.text
                          self.log("Refined on your Mac: \(Self.snippet(r.text)).")
                      case .failure(let e):
                          self.refineError = e
                          // On llmUnavailable the Mac hands the original text back;
                          // keep it so the user doesn't lose their input.
                          if case .llmUnavailable(let original) = e, let original {
                              self.refinedText = original
                          }
                          self.log("Remote refine failed: \(e.userMessage)")
                      }
                  })
    }

    // MARK: - Remote history browse

    func loadHistory(_ peer: PeerIdentity, limit: Int = 20) {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        historyError = nil
        runClient(for: peer,
                  onMissing: { self.isLoadingHistory = false; self.historyError = .notPaired },
                  work: { try $0.remoteHistory(limit: limit) },
                  done: { result in
                      self.isLoadingHistory = false
                      switch result {
                      case .success(let rows):
                          self.history = rows
                          self.log("Loaded \(rows.count) history \(rows.count == 1 ? "entry" : "entries") from your Mac.")
                      case .failure(let e):
                          self.historyError = e
                          self.log("History load failed: \(e.userMessage)")
                      }
                  })
    }

    // MARK: - Off-main execution + result plumbing

    /// Build the client, run `work` off-main, and deliver a
    /// `Result<R, RemoteMacError>` back on the main actor. If no key is stored,
    /// `onMissing` runs on the main actor and `work` is never invoked.
    private func runClient<R: Sendable>(
        for peer: PeerIdentity,
        onMissing: @escaping () -> Void,
        work: @escaping (RemoteMacClient) throws -> R,
        done: @escaping (Result<R, RemoteMacError>) -> Void
    ) {
        guard let client = makeClient(for: peer) else {
            onMissing()
            return
        }
        Task.detached(priority: .userInitiated) {
            let result: Result<R, RemoteMacError>
            do {
                result = .success(try work(client))
            } catch let e as RemoteMacError {
                result = .failure(e)
            } catch {
                result = .failure(.unreachable(detail: error.localizedDescription))
            }
            await MainActor.run { done(result) }
        }
    }

    // MARK: - Journal

    private func log(_ message: String) {
        journal.insert(JournalEntry(date: Date(), message: message), at: 0)
        if journal.count > 20 { journal.removeLast(journal.count - 20) }
    }

    private static func snippet(_ text: String, max: Int = 48) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        return String(trimmed.prefix(max)) + "\u{2026}"
    }
}
