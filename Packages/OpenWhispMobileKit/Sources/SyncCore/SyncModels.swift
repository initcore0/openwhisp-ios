import Foundation
import OpenWhispCore

/// The five syncable sections. Mirrors `BridgeWire.SyncSection` (the wire tokens)
/// but kept as its own pure type so SyncCore doesn't depend on BridgeKit — the
/// SyncKit layer maps between the two.
public enum SyncSection: String, CaseIterable, Codable, Sendable, Equatable {
    case vocabulary
    case profiles
    case modes
    case history
    case packs
}

/// A cheap summary of one peer's history log — enough to decide whether (and from
/// where) to pull without shipping the whole list. The merge is append-only union
/// by entry `id`; `newestDate` is the delta cursor.
public struct SyncHistoryHead: Equatable, Sendable {
    public var count: Int
    public var newestID: UUID?
    /// Newest entry's timestamp (the pull cursor). A puller asks for entries
    /// strictly newer than the cursor it already holds.
    public var newestDate: Date?

    public init(count: Int, newestID: UUID? = nil, newestDate: Date? = nil) {
        self.count = count
        self.newestID = newestID
        self.newestDate = newestDate
    }
}

/// A peer's section digests + history head + per-section newest-`updatedAt`. The
/// local device computes its own manifest and receives the remote's; the pure
/// ``SyncPlanner`` diffs the two into a ``SyncPlan``.
public struct SyncManifest: Equatable, Sendable {
    public var schemaVersion: Int
    public var vocabHash: String
    public var profilesHash: String
    public var modesHash: String
    public var packsHash: String
    public var historyHead: SyncHistoryHead
    /// Per-section newest `updatedAt` — the coarse LWW signal that lets the planner
    /// short-circuit a whole section when neither side has a newer edit. Keyed by
    /// ``SyncSection``.
    public var updatedAt: [SyncSection: Date]

    public init(
        schemaVersion: Int,
        vocabHash: String,
        profilesHash: String,
        modesHash: String,
        packsHash: String,
        historyHead: SyncHistoryHead,
        updatedAt: [SyncSection: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.vocabHash = vocabHash
        self.profilesHash = profilesHash
        self.modesHash = modesHash
        self.packsHash = packsHash
        self.historyHead = historyHead
        self.updatedAt = updatedAt
    }

    /// The content hash for a given section (packs/history use their own signals,
    /// but a hash is defined for every section for uniform diffing).
    public func hash(for section: SyncSection) -> String {
        switch section {
        case .vocabulary: return vocabHash
        case .profiles:   return profilesHash
        case .modes:      return modesHash
        case .packs:      return packsHash
        case .history:    return historyHead.newestID?.uuidString ?? ""
        }
    }
}

/// The plan the local device executes: which sections to PULL from the remote,
/// which to PUSH to it, and the history cursor to pull from. Deterministic output
/// of ``SyncPlanner/plan(local:remote:)`` — fully unit-tested, no I/O.
public struct SyncPlan: Equatable, Sendable {
    /// Sections whose remote copy has (or may have) newer data we should fetch.
    public var pull: Set<SyncSection>
    /// Sections whose local copy has (or may have) newer data we should offer.
    public var push: Set<SyncSection>
    /// History delta cursor: pull only entries strictly newer than this. nil = the
    /// remote has history we've never seen the head of → pull the full log and let
    /// the append-only union dedupe.
    public var historyCursor: Date?

    public init(pull: Set<SyncSection> = [], push: Set<SyncSection> = [], historyCursor: Date? = nil) {
        self.pull = pull
        self.push = push
        self.historyCursor = historyCursor
    }

    /// True when nothing needs to move — a clean idempotent no-op sync.
    public var isNoOp: Bool { pull.isEmpty && push.isEmpty }
}

/// What a completed sync actually did, for the paired-device card + tests. Counts
/// are the entries MERGED INTO THE LOCAL stores (from a pull) and OFFERED to the
/// remote (from a push, echoed back by `sync.push` mergedCounts).
public struct SyncReport: Equatable, Sendable {
    public struct SectionCounts: Equatable, Sendable {
        public var vocabulary: Int
        public var profiles: Int
        public var modes: Int
        public var history: Int
        public var packs: Int

        public init(vocabulary: Int = 0, profiles: Int = 0, modes: Int = 0, history: Int = 0, packs: Int = 0) {
            self.vocabulary = vocabulary
            self.profiles = profiles
            self.modes = modes
            self.history = history
            self.packs = packs
        }

        public var total: Int { vocabulary + profiles + modes + history + packs }
    }

    /// Entries merged into local stores from the remote.
    public var pulled: SectionCounts
    /// Entries the remote reported it merged from our push.
    public var pushed: SectionCounts
    public var startedAt: Date
    public var finishedAt: Date

    public init(pulled: SectionCounts = .init(), pushed: SectionCounts = .init(), startedAt: Date, finishedAt: Date) {
        self.pulled = pulled
        self.pushed = pushed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var didAnything: Bool { pulled.total > 0 || pushed.total > 0 }
}
