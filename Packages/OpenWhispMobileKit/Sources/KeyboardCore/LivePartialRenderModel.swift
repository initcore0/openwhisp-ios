import Foundation
import MobileCore

// MARK: - Live-partial render model (ARCHITECTURE §6.8, decision D12) — WP10c
//
// While a session is capturing, the host streams rolling `LivePartial`s through the
// App Group and the keyboard renders them at the caret. The UIKit shell polls the
// `LivePartialStore` (+ a Darwin ping) and hands each `LivePartial` to this pure
// model, which decides the MINIMAL `UITextDocumentProxy` edit — via `LiveInsertDiffer`
// — that turns what we last rendered into the new text. Keeping this decision here
// (Foundation-only, no proxy) makes the whole loop — out-of-order `seq`, `captureID`
// switch, final swap, secure-field suppression — exhaustively testable.
//
// State kept is intentionally TINY (keyboard jetsam ceiling, ~30–60 MB): only the
// current capture's id, the last `seq` we acted on, and the last string we rendered.
// No partial history is retained — the differ needs only "last rendered" and "next".

public struct LivePartialRenderModel {

    // MARK: - Tracking state (last-rendered only; no history)

    /// The capture whose partials we are currently rendering. `nil` until the first
    /// partial of a capture is applied (or after a final/reset clears tracking).
    public private(set) var captureID: UUID?
    /// The highest `seq` we have acted on for `captureID`. Regressions are ignored.
    public private(set) var lastSeq: Int?
    /// The exact string we last rendered into the field for `captureID`. The differ
    /// diffs FROM this. Empty when a capture is fresh (nothing rendered yet).
    public private(set) var rendered: String

    public init() {
        self.captureID = nil
        self.lastSeq = nil
        self.rendered = ""
    }

    // MARK: - Decision

    /// What the shell should do with one incoming `LivePartial`.
    public enum Decision: Equatable, Sendable {
        /// Apply this edit to the proxy: `deleteBackward` grapheme clusters, then
        /// insert `insert`. The model has already updated its `rendered` tracking to
        /// the partial's text (so the next diff is correct).
        case edit(deleteBackward: Int, insert: String)
        /// Ignore this partial — a `seq` regression / duplicate for the current
        /// capture, or a stale partial from a capture we are no longer rendering.
        /// Tracking is unchanged.
        case ignore
    }

    /// Decide (and record) the edit for `partial`, given the sink's secure-field
    /// state. The secure-field check happens FIRST, before any tracking mutation or
    /// edit math — a session capture NEVER renders into a secure field (§7, D12);
    /// the final falls back to the WP5 pending-transcript path, which also refuses
    /// secure fields. When suppressed, this returns `.ignore` and leaves tracking
    /// untouched (so nothing is ever deleted/inserted in a password field).
    ///
    /// Ordering, deliberately:
    ///   1. `isSecureField` ⇒ `.ignore` (no state change; suppression is total).
    ///   2. A partial for a DIFFERENT `captureID` starts a fresh capture: reset
    ///      tracking (`rendered = ""`), so its first partial is a pure insert. This
    ///      does NOT delete the previous capture's text — the caret simply advances;
    ///      the previous capture's final already settled its own text.
    ///   3. Within the current capture, a non-increasing `seq` is a regression /
    ///      duplicate ⇒ `.ignore` (the store is last-writer-wins, so a slow poll can
    ///      re-see an older write).
    ///   4. Otherwise diff `rendered → partial.text`, advance tracking, and — when
    ///      `isFinal` — clear tracking so the NEXT capture starts clean. The final's
    ///      cleaned text is diffed from the last rendered partial (a wholesale swap
    ///      of just the diverging tail), exactly the D12 "swap in the cleaned final".
    public mutating func apply(_ partial: LivePartial, isSecureField: Bool) -> Decision {
        // 1. Secure field: suppress entirely, decided before any edit or mutation.
        guard !isSecureField else { return .ignore }

        // 2. New capture → reset tracking so its first partial is a pure insert.
        if partial.captureID != captureID {
            captureID = partial.captureID
            lastSeq = nil
            rendered = ""
        }

        // 3. Ignore seq regressions / duplicates within the current capture. The
        //    final is allowed to share or trail the last seq we saw (some hosts stamp
        //    the final with the same seq as the last partial), so it is exempt.
        if let lastSeq, partial.seq <= lastSeq, !partial.isFinal {
            return .ignore
        }

        // 4. Diff last-rendered → this text; advance tracking.
        let edit = LiveInsertDiffer.edits(from: rendered, to: partial.text)
        lastSeq = partial.seq

        if partial.isFinal {
            // The cleaned final settled this capture — clear tracking so the next
            // capture starts from empty (and a late stale partial for THIS capture
            // is treated as a new/foreign capture and won't re-diff against text we
            // no longer own).
            reset()
        } else {
            rendered = partial.text
        }

        return .edit(deleteBackward: edit.deleteBackward, insert: edit.insert)
    }

    /// Clear all tracking (capture ended / rendering stopped / field lost). The next
    /// partial applied starts a fresh capture from empty.
    public mutating func reset() {
        captureID = nil
        lastSeq = nil
        rendered = ""
    }
}
