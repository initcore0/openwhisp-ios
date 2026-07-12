import Foundation
import SyncCore

/// A tiny JSON store for the paired-peer records (``PeerIdentity``). The SECRET
/// (PSK) never lives here — it's in the Keychain, keyed by peer id. This file
/// holds only the non-sensitive metadata the paired-device card renders.
///
/// Injectable `fileURL` so tests point it at a tempdir; the app uses the default
/// Application Support location (inside the app container on iOS).
public final class PeerStore {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = base
                .appendingPathComponent("OpenWhisp", isDirectory: true)
                .appendingPathComponent("paired-peers.json")
        }
    }

    public func load() -> [PeerIdentity] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PeerIdentity].self, from: data)) ?? []
    }

    public func save(_ peers: [PeerIdentity]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(peers) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Insert or replace the record with the same id (a re-pair refreshes it).
    public func upsert(_ peer: PeerIdentity) {
        var peers = load()
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
        save(peers)
    }

    public func remove(_ id: PeerIdentity.ID) {
        save(load().filter { $0.id != id })
    }

    /// Update the `lastSeen` of a peer after a successful sync (no-op if absent).
    public func markSeen(_ id: PeerIdentity.ID, at date: Date = Date()) {
        var peers = load()
        guard let idx = peers.firstIndex(where: { $0.id == id }) else { return }
        peers[idx].lastSeen = date
        save(peers)
    }
}
