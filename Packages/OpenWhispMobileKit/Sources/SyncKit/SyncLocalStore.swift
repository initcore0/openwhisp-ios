import Foundation
import OpenWhispCore
import SyncCore

/// The local persistence the ``SyncEngine`` reads a manifest from and applies a
/// pull into. Abstracted so the engine is driven by an in-memory fake in tests
/// and by the app's real JSON stores in production — the engine itself does no
/// file I/O.
///
/// `snapshot()` gathers everything the manifest + a push need; the `apply*`
/// methods merge a pulled section into local state (using the pure ``SyncMerge``)
/// and return how many rows changed, for the ``SyncReport``.
public protocol SyncLocalStore: AnyObject {
    /// Current local state → the source for our manifest and our push bundle.
    func snapshot() -> SyncManifestBuilder.LocalState

    /// Merge a pulled vocabulary; returns substitutions added/overwritten.
    @discardableResult func applyVocabulary(_ remote: Vocabulary) -> Int
    /// Merge pulled profiles (LWW); returns changed count.
    @discardableResult func applyProfiles(_ remote: [AppProfile]) -> Int
    /// Merge pulled modes (LWW); returns changed count.
    @discardableResult func applyModes(_ remote: [Mode]) -> Int
    /// Append-only union of pulled history; returns entries added.
    @discardableResult func applyHistory(_ remote: [TranscriptionEntry]) -> Int
}

/// The app's live store wiring: adapts the upstream `VocabularyStore` /
/// `AppProfileStore` / `TranscriptionHistoryStore` (same schema + Application
/// Support location as the Mac) to ``SyncLocalStore``. All merges route through
/// the pure ``SyncMerge`` so behavior matches the tested policy exactly.
///
/// `packHashes` is supplied by a closure (the app knows its installed packs);
/// defaults to empty so a build without packs still syncs the other sections.
public final class AppGroupSyncStore: SyncLocalStore {
    private let loadVocabulary: () -> Vocabulary
    private let saveVocabulary: (Vocabulary) -> Void
    private let loadProfiles: () -> [AppProfile]
    private let saveProfiles: ([AppProfile]) -> Void
    private let loadModes: () -> [Mode]
    private let saveModes: ([Mode]) -> Void
    private let loadHistory: () -> [TranscriptionEntry]
    private let saveHistory: ([TranscriptionEntry]) -> Void
    private let packHashes: () -> [String]

    public init(
        loadVocabulary: @escaping () -> Vocabulary,
        saveVocabulary: @escaping (Vocabulary) -> Void,
        loadProfiles: @escaping () -> [AppProfile],
        saveProfiles: @escaping ([AppProfile]) -> Void,
        loadModes: @escaping () -> [Mode],
        saveModes: @escaping ([Mode]) -> Void,
        loadHistory: @escaping () -> [TranscriptionEntry],
        saveHistory: @escaping ([TranscriptionEntry]) -> Void,
        packHashes: @escaping () -> [String] = { [] }
    ) {
        self.loadVocabulary = loadVocabulary
        self.saveVocabulary = saveVocabulary
        self.loadProfiles = loadProfiles
        self.saveProfiles = saveProfiles
        self.loadModes = loadModes
        self.saveModes = saveModes
        self.loadHistory = loadHistory
        self.saveHistory = saveHistory
        self.packHashes = packHashes
    }

    public func snapshot() -> SyncManifestBuilder.LocalState {
        SyncManifestBuilder.LocalState(
            vocabulary: loadVocabulary(),
            profiles: loadProfiles(),
            modes: loadModes(),
            packHashes: packHashes(),
            history: loadHistory()
        )
    }

    public func applyVocabulary(_ remote: Vocabulary) -> Int {
        let (merged, changed) = SyncMerge.mergeVocabulary(local: loadVocabulary(), remote: remote)
        if changed > 0 { saveVocabulary(merged) }
        return changed
    }

    public func applyProfiles(_ remote: [AppProfile]) -> Int {
        let (merged, changed) = SyncMerge.mergeProfiles(local: loadProfiles(), remote: remote)
        if changed > 0 { saveProfiles(merged) }
        return changed
    }

    public func applyModes(_ remote: [Mode]) -> Int {
        let (merged, changed) = SyncMerge.mergeModes(local: loadModes(), remote: remote)
        if changed > 0 { saveModes(merged) }
        return changed
    }

    public func applyHistory(_ remote: [TranscriptionEntry]) -> Int {
        let (merged, added) = SyncMerge.mergeHistory(local: loadHistory(), remote: remote)
        if added > 0 { saveHistory(merged) }
        return added
    }
}
