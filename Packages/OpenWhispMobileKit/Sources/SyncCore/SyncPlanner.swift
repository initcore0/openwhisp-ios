import Foundation

/// The pure sync planner: diff two ``SyncManifest``s into a ``SyncPlan`` telling
/// the local device which sections to pull and which to push. No I/O, no clock —
/// deterministic and fully unit-tested (ARCHITECTURE §6.5/§8).
///
/// The merge is a *union* in both directions, so the planner is conservative: if
/// a section's content hashes differ, EACH side may hold rows the other lacks, so
/// we both pull it and push it and let the pure ``SyncMerge`` union dedupe. The
/// per-section `updatedAt` map is used only to (a) pick a history pull cursor and
/// (b) skip a section entirely when the hashes already match (a true no-op).
///
/// This keeps a re-sync IDEMPOTENT: once both sides converged, all hashes match,
/// the plan is empty, and no bytes move.
public struct SyncPlanner {
    public init() {}

    /// Diff `local` against `remote` (as reported by `sync.manifest`).
    public func plan(local: SyncManifest, remote: SyncManifest) -> SyncPlan {
        var pull: Set<SyncSection> = []
        var push: Set<SyncSection> = []

        // Config-ish sections: union both ways whenever the content differs. The
        // hash is content identity, so equal hashes ⇒ identical section ⇒ skip.
        for section in [SyncSection.vocabulary, .profiles, .modes, .packs] {
            if local.hash(for: section) != remote.hash(for: section) {
                pull.insert(section)
                push.insert(section)
            }
        }

        // History: append-only union by id. If the heads match by id, both logs
        // share a newest entry and we treat history as converged. Otherwise each
        // side may hold entries the other lacks — and crucially those "new to us"
        // entries are NOT guaranteed to be newer than our own head (a device that
        // was offline can hold an OLD dictation we've never seen). So the pull
        // cursor is left nil: we pull the FULL remote log and let the id-keyed
        // union dedupe. That is what keeps a two-way history sync correct and
        // idempotent; a date-cursor delta would silently drop older-but-unseen
        // entries. The cursor field on the wire is reserved for a future
        // optimization once entries carry a monotonic sequence.
        let historyDiffers = local.historyHead.newestID != remote.historyHead.newestID
        if historyDiffers {
            // Pull only if the remote actually has entries.
            if remote.historyHead.count > 0 { pull.insert(.history) }
            // Push only if WE actually have entries to offer.
            if local.historyHead.count > 0 { push.insert(.history) }
        }

        return SyncPlan(pull: pull, push: push, historyCursor: nil)
    }
}
