import Foundation
import MobileCore

// MARK: - Transcript insert policy (ARCHITECTURE §6.4)
//
// Pure policy: given the caret context and a transcript, decide the leading
// space and capitalization, and decide whether insertion is permitted at all.
// Delegates sentence conventions to the SmartFormatter contract from upstream;
// here we implement the caret-adjacency spacing and sentence-start capitalization
// that the keyboard needs locally, plus the two hard refusals (expiry, secure
// field) that the security model (§7) requires.

public struct TranscriptInsertPolicy: Sendable {

    public init() {}

    // MARK: Permission (hard refusals)

    /// Whether the transcript may be inserted at all, given the field and clock.
    ///
    /// Refuses when:
    /// - the field is secure (password) — mirrors the mac `SecureFieldPolicy`
    ///   contract; on iOS the signal is `isSecureTextEntry`. A stale dictation
    ///   must never land in a password field.
    /// - the transcript has expired (`now >= expiresAt`, 120 s after creation).
    ///
    /// (Full Access is required to *read* the transcript at all, so it is not a
    /// gate here — by the time we hold a `PendingTranscript` the store read has
    /// already succeeded. The keyboard's own Full-Access explainer is handled by
    /// `MicKeyResolver`, upstream of this policy.)
    public func permitted(_ t: PendingTranscript, sink: KeyboardTextSink, now: Date) -> Bool {
        if sink.isSecureField { return false }
        if t.isExpired(now: now) { return false }
        return true
    }

    // MARK: Rendering (spacing + capitalization)

    /// The exact string to insert, given the caret context.
    ///
    /// Spacing rule: if there is preceding text that does not already end in
    /// whitespace, and the transcript does not already begin with whitespace or a
    /// closing punctuation mark, prepend a single space so words don't collide.
    /// At the very start of a field (nil/empty context) no leading space is added.
    ///
    /// Capitalization rule: if the caret is at a sentence start — the field is
    /// empty, or the preceding non-space character is a sentence-ending
    /// punctuation mark (`.`, `!`, `?`) — the first alphabetic character of the
    /// transcript is uppercased. Otherwise the transcript's own casing is kept
    /// (the host's `TranscriptCleaner` already ran, so mid-sentence text arrives
    /// correctly cased).
    public func rendered(_ t: PendingTranscript, context: String?) -> String {
        var text = t.text
        guard !text.isEmpty else { return text }

        let trimmedContext = context ?? ""

        if shouldCapitalizeFirstLetter(context: trimmedContext) {
            text = capitalizingFirstLetter(text)
        }

        if shouldPrependSpace(context: trimmedContext, insertion: text) {
            text = " " + text
        }

        return text
    }

    // MARK: - Spacing helpers

    private func shouldPrependSpace(context: String, insertion: String) -> Bool {
        // No preceding text → no leading space (start of field).
        guard let lastChar = context.last else { return false }
        // Preceding text already ends in whitespace → no extra space.
        if lastChar.isWhitespace { return false }
        // Insertion already begins with whitespace → don't double it.
        if let first = insertion.first, first.isWhitespace { return false }
        // Insertion begins with a closing punctuation that hugs the previous word
        // (e.g. ", world" or ". Next") → no leading space so the punctuation
        // attaches correctly.
        if let first = insertion.first, Self.closingPunctuation.contains(first) {
            return false
        }
        return true
    }

    // MARK: - Capitalization helpers

    private func shouldCapitalizeFirstLetter(context: String) -> Bool {
        // Sentence start at the beginning of an empty field.
        let trimmed = context.reversed().drop(while: { $0.isWhitespace })
        guard let lastNonSpace = trimmed.first else {
            // Context is empty or all whitespace → sentence start.
            return true
        }
        return Self.sentenceTerminators.contains(lastNonSpace)
    }

    private func capitalizingFirstLetter(_ s: String) -> String {
        guard let idx = s.firstIndex(where: { $0.isLetter }) else { return s }
        // Only capitalize when the first *letter* is the first meaningful char;
        // if leading non-letters precede it (quotes, brackets), still uppercase
        // the first letter, matching sentence conventions like ("hello → "Hello.
        let prefix = s[s.startIndex..<idx]
        let letter = s[idx]
        let rest = s[s.index(after: idx)...]
        return String(prefix) + String(letter).uppercased() + String(rest)
    }

    // MARK: - Character sets

    /// Sentence-ending punctuation: after one of these, the next word starts a
    /// new sentence and is capitalized.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// Closing punctuation that should hug the preceding word (no leading space).
    private static let closingPunctuation: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "'", "\""]
}
