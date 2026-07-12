import Foundation
import MobileCore

// MARK: - Transcript inserter (ARCHITECTURE §6.4, §5, §7)
//
// The one code path that turns a pending transcript into inserted text. It ties
// the three tested pieces together so the UIKit extension never re-implements the
// rules: it (1) atomically CONSUMES the transcript from the store exactly once,
// (2) runs the `TranscriptInsertPolicy` refusals (secure field, expiry), and
// (3) renders spacing/caps and writes to the sink. Because the store consume is
// atomic and single-shot, calling this twice for the same id inserts at most
// once — the R0c idempotency guarantee, provable with an in-memory sink + a real
// tempdir store in `swift test`.

public struct TranscriptInserter {

    private let policy: TranscriptInsertPolicy

    public init(policy: TranscriptInsertPolicy = TranscriptInsertPolicy()) {
        self.policy = policy
    }

    /// The outcome of an insert attempt, returned so the caller can update UI
    /// (and so tests can assert exactly what happened without inspecting the sink).
    public enum Outcome: Equatable, Sendable {
        /// Inserted `text` into the sink.
        case inserted(String)
        /// Nothing pending under `id` (already consumed, gone, or never there).
        case nothingPending
        /// Consumed but refused by policy (secure field or expired). The store
        /// slot is emptied either way — a refused transcript is not left to linger.
        case refused
    }

    /// Attempt to insert the pending transcript identified by `id`.
    ///
    /// Ordering is deliberate: we CONSUME first (atomic single-shot), so a racing
    /// second call — or a repeated refresh trigger — finds nothing and cannot
    /// double-insert. Only after we hold the transcript do we apply the policy
    /// refusals; a refused transcript has already been removed from the mailbox by
    /// the consume, satisfying "a stale dictation must never linger" (§7).
    @discardableResult
    public func insert(
        id: UUID,
        from store: DictationHandoffStore,
        into sink: KeyboardTextSink,
        now: Date
    ) throws -> Outcome {
        guard let transcript = try store.consume(id: id, now: now) else {
            // consume() returns nil for: already consumed, id mismatch, OR expired
            // (expiry is enforced inside the store, which also destroys the slot).
            return .nothingPending
        }

        // Belt-and-suspenders: the store already refused an expired transcript, but
        // the policy is the security contract — re-check secure field + expiry here
        // so the refusal is enforced at the insert seam regardless of store impl.
        guard policy.permitted(transcript, sink: sink, now: now) else {
            return .refused
        }

        let text = policy.rendered(transcript, context: sink.contextBeforeCaret)
        sink.insert(text)
        return .inserted(text)
    }
}
