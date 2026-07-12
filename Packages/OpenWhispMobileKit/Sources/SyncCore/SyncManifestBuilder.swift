import Foundation
import CryptoKit
import OpenWhispCore

/// Computes a ``SyncManifest`` from local state (vocabulary / profiles / modes /
/// packs / history). Pure and deterministic: the same content always yields the
/// same section hashes, so two devices that converged report identical manifests
/// and the planner sees a no-op. The hash is an *identity* digest only — it is
/// never reversed and carries no data.
///
/// Hashing is order-insensitive where the underlying collection is a set-like
/// union (substitutions, profiles, modes are keyed by id), so a reorder that
/// doesn't change content doesn't spuriously force a sync.
public enum SyncManifestBuilder {

    /// Everything the manifest needs, gathered by the host app from its stores.
    public struct LocalState {
        public var vocabulary: Vocabulary
        public var profiles: [AppProfile]
        public var modes: [Mode]
        /// Content hashes of installed packs (pack identity is content-hash — the
        /// app supplies these; SyncCore treats them opaquely). Order-insensitive.
        public var packHashes: [String]
        public var history: [TranscriptionEntry]

        public init(
            vocabulary: Vocabulary = .empty,
            profiles: [AppProfile] = [],
            modes: [Mode] = [],
            packHashes: [String] = [],
            history: [TranscriptionEntry] = []
        ) {
            self.vocabulary = vocabulary
            self.profiles = profiles
            self.modes = modes
            self.packHashes = packHashes
            self.history = history
        }
    }

    public static func manifest(for state: LocalState) -> SyncManifest {
        SyncManifest(
            schemaVersion: ConfigBundle.currentSchemaVersion,
            vocabHash: vocabHash(state.vocabulary),
            profilesHash: idStampHash(state.profiles, id: { $0.id }, stamp: { $0.updatedAt }),
            modesHash: idStampHash(state.modes, id: { $0.id }, stamp: { $0.updatedAt }),
            packsHash: setHash(state.packHashes),
            historyHead: historyHead(state.history),
            updatedAt: [
                .vocabulary: newestStamp(state.vocabulary.substitutions.map(\.updatedAt)),
                .profiles: newestStamp(state.profiles.map(\.updatedAt)),
                .modes: newestStamp(state.modes.map(\.updatedAt)),
                .history: state.history.map(\.date).max() ?? .distantPast,
            ]
        )
    }

    // MARK: - Section hashes

    static func vocabHash(_ v: Vocabulary) -> String {
        // Substitutions keyed by id+stamp+content; terms as a set. Both sorted so
        // order doesn't affect the digest.
        let subs = v.substitutions
            .map { "\($0.id.uuidString)|\($0.from)|\($0.to)|\($0.starred)|\(stampKey($0.updatedAt))" }
            .sorted()
        let terms = v.terms.sorted()
        return digest(["subs"] + subs + ["terms"] + terms)
    }

    static func idStampHash<T>(_ items: [T], id: (T) -> UUID, stamp: (T) -> Date) -> String {
        let rows = items.map { "\(id($0).uuidString)|\(stampKey(stamp($0)))" }.sorted()
        return digest(rows)
    }

    static func setHash(_ values: [String]) -> String {
        digest(values.sorted())
    }

    static func historyHead(_ entries: [TranscriptionEntry]) -> SyncHistoryHead {
        guard let newest = entries.max(by: { $0.date < $1.date }) else {
            return SyncHistoryHead(count: 0, newestID: nil, newestDate: nil)
        }
        return SyncHistoryHead(count: entries.count, newestID: newest.id, newestDate: newest.date)
    }

    // MARK: - helpers

    private static func newestStamp(_ dates: [Date]) -> Date { dates.max() ?? .distantPast }

    /// A stable string key for a Date at millisecond resolution — matches the
    /// wire's ISO-8601-with-fractional-seconds precision so a value that
    /// round-tripped through the wire still hashes identically.
    private static func stampKey(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970)
    }

    private static func digest(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "\n")
        let d = SHA256.hash(data: Data(joined.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }
}
