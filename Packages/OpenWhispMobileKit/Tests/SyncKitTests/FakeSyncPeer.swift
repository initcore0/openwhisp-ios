import Foundation
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore
@testable import SyncKit

/// An in-process fake Mac that answers the three sync verbs by running the SAME
/// pure merge policy on its own state — so an engine sync against it is a faithful
/// two-way merge with no network. Conforms to the upstream `BridgeSession`, so it
/// plugs straight into `SyncEngine.run(with:)`.
final class FakeSyncPeer: BridgeSession {
    var vocabulary: Vocabulary
    var profiles: [AppProfile]
    var modes: [Mode]
    var history: [TranscriptionEntry]
    var offersSyncCapability = true

    private(set) var handshakeCount = 0
    private(set) var pushedBundles = 0

    init(vocabulary: Vocabulary = .empty, profiles: [AppProfile] = [],
         modes: [Mode] = [], history: [TranscriptionEntry] = []) {
        self.vocabulary = vocabulary
        self.profiles = profiles
        self.modes = modes
        self.history = history
    }

    func handshake(clientName: String) throws {
        handshakeCount += 1
        // The transport's TCPBridgeSession does the capability check; the fake is
        // fed straight to the engine, so we don't gate here — but a flag exists so
        // a negative test could flip it.
        _ = offersSyncCapability
    }

    func call<P, R>(method: String, params: P?, resultType: R.Type) throws -> R
        where P: Codable & Sendable, R: Decodable
    {
        // Round-trip params/results through JSON so the fake exercises the same
        // Codable path the real wire does (catches shape mismatches).
        switch method {
        case BridgeWire.Method.syncManifest.rawValue:
            return try decode(manifestResult(), as: R.self)

        case BridgeWire.Method.syncPull.rawValue:
            let p = try reencode(params, as: BridgeWire.SyncPullParams.self)
            return try decode(pullResult(p), as: R.self)

        case BridgeWire.Method.syncPush.rawValue:
            let p = try reencode(params, as: BridgeWire.SyncBundleResult.self)
            return try decode(pushResult(p), as: R.self)

        default:
            throw TCPBridgeSession.SessionError.domain(reason: .unknownMethod, message: "unknown \(method)")
        }
    }

    // MARK: verb handlers (mirror the WP6-mac server semantics)

    private func manifestResult() -> BridgeWire.SyncManifestResult {
        let state = SyncManifestBuilder.LocalState(
            vocabulary: vocabulary, profiles: profiles, modes: modes, history: history)
        let m = SyncManifestBuilder.manifest(for: state)
        var updated: [String: String] = [:]
        for (section, date) in m.updatedAt {
            updated[section.rawValue] = BridgeWire.iso8601String(from: date)
        }
        let head = BridgeWire.SyncHistoryHead(
            count: m.historyHead.count,
            newestID: m.historyHead.newestID,
            newestDate: m.historyHead.newestDate.map(BridgeWire.iso8601String(from:)))
        return BridgeWire.SyncManifestResult(
            schemaVersion: m.schemaVersion, vocabHash: m.vocabHash, profilesHash: m.profilesHash,
            modesHash: m.modesHash, packsHash: m.packsHash, historyHead: head, updatedAt: updated)
    }

    private func pullResult(_ params: BridgeWire.SyncPullParams) -> BridgeWire.SyncBundleResult {
        let want = Set(params.want ?? BridgeWire.SyncSection.allCases)
        let bundle = ConfigBundle(
            profiles: want.contains(.profiles) ? profiles : nil,
            modes: want.contains(.modes) ? modes : nil,
            vocabulary: want.contains(.vocabulary) ? vocabulary : nil)
        var entries: [TranscriptionEntry] = []
        if want.contains(.history) {
            if let cursorStr = params.sinceHistoryCursor, let cursor = BridgeWire.date(fromISO8601: cursorStr) {
                entries = history.filter { $0.date > cursor }
            } else {
                entries = history
            }
        }
        return BridgeWire.SyncBundleResult(bundle: bundle, historyEntries: entries)
    }

    private func pushResult(_ offer: BridgeWire.SyncBundleResult) -> BridgeWire.SyncPushResult {
        pushedBundles += 1
        var counts = BridgeWire.SyncMergedCounts()
        if let v = offer.bundle.vocabulary {
            let (merged, changed) = SyncMerge.mergeVocabulary(local: vocabulary, remote: v)
            vocabulary = merged; counts.vocabulary = changed
        }
        if let p = offer.bundle.profiles {
            let (merged, changed) = SyncMerge.mergeProfiles(local: profiles, remote: p)
            profiles = merged; counts.profiles = changed
        }
        if let m = offer.bundle.modes {
            let (merged, changed) = SyncMerge.mergeModes(local: modes, remote: m)
            modes = merged; counts.modes = changed
        }
        if !offer.historyEntries.isEmpty {
            let (merged, added) = SyncMerge.mergeHistory(local: history, remote: offer.historyEntries)
            history = merged; counts.history = added
        }
        return BridgeWire.SyncPushResult(accepted: true, mergedCounts: counts)
    }

    // MARK: Codable bridging

    private func reencode<P: Encodable, T: Decodable>(_ params: P?, as: T.Type) throws -> T {
        let data = try JSONEncoder().encode(params)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func decode<T: Encodable, R: Decodable>(_ value: T, as: R.Type) throws -> R {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(R.self, from: data)
    }
}

/// An in-memory ``SyncLocalStore`` for the engine under test.
final class InMemorySyncStore: SyncLocalStore {
    var vocabulary: Vocabulary
    var profiles: [AppProfile]
    var modes: [Mode]
    var history: [TranscriptionEntry]

    init(vocabulary: Vocabulary = .empty, profiles: [AppProfile] = [],
         modes: [Mode] = [], history: [TranscriptionEntry] = []) {
        self.vocabulary = vocabulary
        self.profiles = profiles
        self.modes = modes
        self.history = history
    }

    func snapshot() -> SyncManifestBuilder.LocalState {
        SyncManifestBuilder.LocalState(vocabulary: vocabulary, profiles: profiles, modes: modes, history: history)
    }
    func applyVocabulary(_ remote: Vocabulary) -> Int {
        let (m, c) = SyncMerge.mergeVocabulary(local: vocabulary, remote: remote); vocabulary = m; return c
    }
    func applyProfiles(_ remote: [AppProfile]) -> Int {
        let (m, c) = SyncMerge.mergeProfiles(local: profiles, remote: remote); profiles = m; return c
    }
    func applyModes(_ remote: [Mode]) -> Int {
        let (m, c) = SyncMerge.mergeModes(local: modes, remote: remote); modes = m; return c
    }
    func applyHistory(_ remote: [TranscriptionEntry]) -> Int {
        let (m, a) = SyncMerge.mergeHistory(local: history, remote: remote); history = m; return a
    }
}
