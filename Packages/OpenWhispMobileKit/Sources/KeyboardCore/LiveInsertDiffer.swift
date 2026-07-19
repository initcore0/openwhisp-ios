import Foundation

// MARK: - Live-insert differ (ARCHITECTURE §6.8, decision D12)
//
// While capturing in a session, the host streams rolling PARTIALS through the App
// Group and the keyboard renders them at the caret via `UITextDocumentProxy` diff
// edits: delete some suffix, then insert. This pure differ computes the minimal
// such edit turning the previously-rendered partial into the next one. Keeping
// the edit math here (Foundation-only, no proxy) makes it exhaustively testable.
//
// Grapheme correctness is load-bearing: `UITextDocumentProxy.deleteBackward()`
// deletes ONE user-perceived character (one Swift `Character` / grapheme cluster)
// per call — NOT one UTF-16 unit and NOT one Unicode scalar. So `deleteBackward`
// here counts CHARACTERS: an emoji or a base+combining-mark sequence is a single
// backspace, never several. The differ works entirely over `Character`s to match.

public struct LiveInsertDiffer {

    /// The minimal edit that turns `rendered` into `next`.
    ///
    /// Strategy: keep the longest common PREFIX (measured in grapheme clusters),
    /// delete everything after it (one `deleteBackward` per trailing character),
    /// then insert the remainder of `next`. This is exactly what a caret-anchored
    /// live insertion can do with `UITextDocumentProxy` (delete-suffix + insert),
    /// and it is optimal for the common case (prefix growth ⇒ zero deletes, pure
    /// insert; a mid-string revision or shrink deletes only the diverging tail).
    ///
    /// - `deleteBackward`: how many times to call `deleteBackward()` (a count of
    ///   grapheme clusters, matching the proxy's one-Character-per-call behavior).
    /// - `insert`: the string to insert afterward (may be empty).
    public static func edits(from rendered: String, to next: String)
        -> (deleteBackward: Int, insert: String) {
        // Work over grapheme clusters so emoji / combining marks count as one.
        let renderedChars = Array(rendered)
        let nextChars = Array(next)

        // Longest common prefix, in characters.
        var common = 0
        let limit = min(renderedChars.count, nextChars.count)
        while common < limit && renderedChars[common] == nextChars[common] {
            common += 1
        }

        let deleteBackward = renderedChars.count - common
        let insert = String(nextChars[common...])
        return (deleteBackward, insert)
    }
}
