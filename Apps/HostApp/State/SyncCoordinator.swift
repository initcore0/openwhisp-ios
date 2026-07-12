import Foundation
import Combine
import OpenWhispCore
import SyncCore
import SyncKit

/// The host-app front end for P2P sync (ARCHITECTURE §6.5). Owns the
/// ``PairingService`` (Keychain + peer store), the ``BonjourPeerTransport``, and
/// the ``SyncEngine`` wired to the app's real on-disk stores. Foreground-only: no
/// daemon — it syncs on `syncNow()` and on app-foreground when a paired peer
/// resolves within a short browse window (`autoSyncOnForeground`).
///
/// Everything network-facing runs off the main actor; only the published state
/// the UI observes is updated on the main actor. Failures are non-fatal and land
/// in ``journal`` (shown on the paired-device card), matching the "fail silent,
/// log to a small sync journal" requirement.
@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var pairedPeers: [PeerIdentity] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var lastReport: SyncReport?
    @Published private(set) var journal: [JournalEntry] = []
    @Published var lastError: String?

    struct JournalEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let message: String
    }

    private let pairing: PairingService
    private let transport: PeerTransport
    private let store: SyncLocalStore
    private let clientName: String

    /// Production wiring: Keychain-backed pairing, Bonjour transport, and the
    /// app's real vocabulary/profiles/modes/history JSON stores (same schema +
    /// location as the Mac, so entries move without translation).
    init(
        pairing: PairingService? = nil,
        transport: PeerTransport = BonjourPeerTransport(),
        store: SyncLocalStore? = nil,
        clientName: String = "iPhone"
    ) {
        self.pairing = pairing ?? DefaultPairingService(secrets: KeychainSecretStore())
        self.transport = transport
        self.store = store ?? Self.makeLiveStore()
        self.clientName = clientName
        self.pairedPeers = self.pairing.pairedPeers
    }

    /// Wire ``SyncEngine`` to the upstream stores (`VocabularyStore` /
    /// `AppProfileStore` / `ModeStore` / `TranscriptionHistoryStore`). All merges
    /// route through the pure ``SyncMerge`` inside ``AppGroupSyncStore``.
    private static func makeLiveStore() -> SyncLocalStore {
        AppGroupSyncStore(
            loadVocabulary: { VocabularyStore.load() },
            saveVocabulary: { VocabularyStore.save($0) },
            loadProfiles: { AppProfileStore.load() },
            saveProfiles: { AppProfileStore.save($0) },
            loadModes: { ModeStore.load() },
            saveModes: { ModeStore.save($0) },
            loadHistory: { TranscriptionHistoryStore.load() },
            saveHistory: { TranscriptionHistoryStore.save($0) }
        )
    }

    // MARK: - Pairing

    /// Complete pairing from a scanned QR payload. Throws on a bad/garbage/future
    /// payload so the scan sheet can show a precise message.
    @discardableResult
    func completePairing(scannedQR: Data) throws -> PeerIdentity {
        let peer = try pairing.completePairing(scannedQR: scannedQR)
        pairedPeers = pairing.pairedPeers
        log("Paired with \(peer.displayName).")
        return peer
    }

    func unpair(_ peer: PeerIdentity) {
        try? pairing.unpair(peer.id)
        pairedPeers = pairing.pairedPeers
        log("Unpaired \(peer.displayName). Key destroyed.")
    }

    // MARK: - Sync

    /// Sync the given peer now. Runs the transport + engine off-main; updates
    /// published state + journal on completion. Never throws to the caller.
    func syncNow(_ peer: PeerIdentity) {
        guard !isSyncing else { return }
        guard let psk = pairing.psk(for: peer.id) else {
            lastError = "No key stored for \(peer.displayName). Re-pair to sync."
            log("Sync skipped: missing key for \(peer.displayName).")
            return
        }
        isSyncing = true
        lastError = nil
        let transport = self.transport
        let store = self.store
        let clientName = self.clientName

        Task.detached(priority: .userInitiated) {
            let result: Result<SyncReport, Error>
            do {
                let session = try transport.connect(to: peer, psk: psk, clientName: clientName)
                let engine = SyncEngine(store: store)
                let report = try engine.run(with: session)
                if let closable = session as? TCPBridgeSession { closable.close() }
                result = .success(report)
            } catch {
                result = .failure(error)
            }
            await self.finishSync(peer: peer, result: result)
        }
    }

    private func finishSync(peer: PeerIdentity, result: Result<SyncReport, Error>) {
        isSyncing = false
        switch result {
        case .success(let report):
            lastReport = report
            markSeen(peer)
            if report.didAnything {
                log("Synced \(peer.displayName): pulled \(report.pulled.total), pushed \(report.pushed.total).")
            } else {
                log("Synced \(peer.displayName): already up to date.")
            }
        case .failure(let error):
            lastError = Self.describe(error)
            log("Sync with \(peer.displayName) failed: \(Self.describe(error))")
        }
    }

    private func markSeen(_ peer: PeerIdentity) {
        // Persist the lastSeen stamp, then refresh the observed list so the card
        // updates. The persisted peer store is the source of truth.
        PeerStore().markSeen(peer.id)
        pairedPeers = pairing.pairedPeers
    }

    // MARK: - Auto-sync on foreground

    /// Called on app-foreground: browse briefly and sync any paired peer that
    /// resolves. Fail-silent (journal only) so a Mac that's asleep is a no-op, not
    /// an error banner.
    func autoSyncOnForeground() {
        for peer in pairedPeers { syncNow(peer) }
    }

    // MARK: - Journal

    private func log(_ message: String) {
        journal.insert(JournalEntry(date: Date(), message: message), at: 0)
        if journal.count > 20 { journal.removeLast(journal.count - 20) }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? BonjourPeerTransport.TransportError {
            switch e {
            case .peerNotFound: return "Couldn't find your Mac on this Wi-Fi. Make sure OpenWhisp is open on it."
            }
        }
        if let e = error as? TCPBridgeSession.SessionError {
            switch e {
            case .notConnected: return "Not connected."
            case .transport(let m): return "Connection problem: \(m)"
            case .undecodable(let m): return "Unexpected response: \(m)"
            case .domain(_, let m, _): return m
            case .unsupportedVersion: return "Your Mac's OpenWhisp is too old to sync. Update it."
            }
        }
        return error.localizedDescription
    }
}
