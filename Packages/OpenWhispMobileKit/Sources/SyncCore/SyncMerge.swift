import Foundation
import OpenWhispCore

/// The v1 merge policy (ARCHITECTURE §6.5, "deliberately boring"):
///
///   - **vocabulary** = union by `Substitution.id`, newer `updatedAt` wins per
///     entry; `terms` = set union (order-preserving, deduped).
///   - **history**    = append-only union by entry `id` (never deletes; a shared
///     `id` keeps the local copy — same id ⇒ same immutable entry).
///   - **profiles / modes** = last-writer-wins per object by `updatedAt`.
///   - **packs**      = content-hash identity (handled at the section level).
///
/// Every function here is PURE and value-semantic (no I/O, no clocks), so the
/// whole policy is exercised by `swift test` — including the idempotency law
/// (merging a result with either input again changes nothing).
public enum SyncMerge {

    // MARK: - Vocabulary

    /// Union two vocabularies. Substitutions merge by `id` (newer `updatedAt`
    /// wins; ties keep `local` so a self-merge is stable). Terms are a set union
    /// that preserves local order then appends new remote terms.
    ///
    /// Returns the merged vocabulary and the count of substitutions that were
    /// newly added or overwritten from `remote` (for the ``SyncReport``).
    public static func mergeVocabulary(local: Vocabulary, remote: Vocabulary)
        -> (merged: Vocabulary, changed: Int)
    {
        var byID: [UUID: Vocabulary.Substitution] = [:]
        var order: [UUID] = []
        for sub in local.substitutions {
            if byID[sub.id] == nil { order.append(sub.id) }
            byID[sub.id] = sub
        }

        var changed = 0
        for sub in remote.substitutions {
            if let existing = byID[sub.id] {
                // Newer stamp wins. Strict `>`: an equal stamp keeps local (stable,
                // so re-merging the same data is a no-op).
                if sub.updatedAt > existing.updatedAt {
                    byID[sub.id] = sub
                    changed += 1
                }
            } else {
                byID[sub.id] = sub
                order.append(sub.id)
                changed += 1
            }
        }

        let mergedSubs = order.compactMap { byID[$0] }

        // Terms: set union, local order first, then remote's novel terms in order.
        var seen = Set<String>()
        var mergedTerms: [String] = []
        for t in local.terms where seen.insert(t).inserted { mergedTerms.append(t) }
        for t in remote.terms where seen.insert(t).inserted { mergedTerms.append(t) }

        return (Vocabulary(terms: mergedTerms, substitutions: mergedSubs), changed)
    }

    // MARK: - History (append-only union by id)

    /// Append-only union of two history logs, keyed by entry `id`. Local entries
    /// win a shared id (same id ⇒ the same immutable dictation). Order: the union
    /// sorted newest-first by `date`, with an `id` tiebreak for determinism.
    ///
    /// Returns the merged log and how many remote entries were genuinely new.
    public static func mergeHistory(local: [TranscriptionEntry], remote: [TranscriptionEntry])
        -> (merged: [TranscriptionEntry], added: Int)
    {
        var byID: [UUID: TranscriptionEntry] = [:]
        for e in local { byID[e.id] = e }

        var added = 0
        for e in remote where byID[e.id] == nil {
            byID[e.id] = e
            added += 1
        }

        let merged = byID.values.sorted { a, b in
            if a.date != b.date { return a.date > b.date }        // newest first
            return a.id.uuidString > b.id.uuidString               // stable tiebreak
        }
        return (merged, added)
    }

    // MARK: - Profiles / Modes (last-writer-wins per object)

    /// Last-writer-wins union of app profiles by `id` (newer `updatedAt` wins;
    /// ties keep local). Returns the merged list (in local-then-new-remote order)
    /// and the count taken/overwritten from remote.
    public static func mergeProfiles(local: [AppProfile], remote: [AppProfile])
        -> (merged: [AppProfile], changed: Int)
    {
        lastWriterWins(local: local, remote: remote, id: \.id, stamp: \.updatedAt)
    }

    /// Last-writer-wins union of modes by `id`.
    public static func mergeModes(local: [Mode], remote: [Mode])
        -> (merged: [Mode], changed: Int)
    {
        lastWriterWins(local: local, remote: remote, id: \.id, stamp: \.updatedAt)
    }

    /// Generic LWW-by-id union preserving local order then appending new remote
    /// objects. A remote object with a strictly newer stamp overwrites in place
    /// (keeping the local slot's position). Equal stamps keep local — so a
    /// self-merge is the identity.
    private static func lastWriterWins<T>(
        local: [T], remote: [T], id: (T) -> UUID, stamp: (T) -> Date
    ) -> (merged: [T], changed: Int) {
        var order: [UUID] = []
        var byID: [UUID: T] = [:]
        for obj in local {
            if byID[id(obj)] == nil { order.append(id(obj)) }
            byID[id(obj)] = obj
        }

        var changed = 0
        for obj in remote {
            let key = id(obj)
            if let existing = byID[key] {
                if stamp(obj) > stamp(existing) {
                    byID[key] = obj
                    changed += 1
                }
            } else {
                byID[key] = obj
                order.append(key)
                changed += 1
            }
        }
        return (order.compactMap { byID[$0] }, changed)
    }
}
