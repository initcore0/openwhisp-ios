import Foundation

// MARK: - Word Error Rate + word-level diff (Engine Lab, WP3)
//
// The Engine Lab's whole reason to exist is to make "OpenWhisp is provably better
// than Apple's built-in recognizer, especially multilingual" (product Goal #1) a
// MEASURED claim rather than a vibe. That measurement is Word Error Rate against a
// known reference transcript, plus a word-level diff so a human can see exactly
// which words each engine got wrong.
//
// This is pure Foundation string/array logic — no engine, no OS surface — so it is
// exhaustively unit-tested on the `swift test` gate (the working-agreement law:
// anything decision-like lives in the tested core, never trapped in a view).
//
// WER = (Substitutions + Deletions + Insertions) / ReferenceWordCount, the standard
// Levenshtein-alignment definition used across the ASR literature. We compute the
// alignment once (Wagner–Fischer DP with backtrace) and derive BOTH the counts and
// the human-readable diff from that single alignment, so the number and the
// highlighted diff can never disagree.

/// One aligned step between the reference and hypothesis word sequences.
public enum DiffOp: String, Codable, Equatable, Sendable {
    /// The word matches (reference == hypothesis at this position).
    case equal
    /// The hypothesis has a different word than the reference (both present).
    case substitute
    /// The reference word is missing from the hypothesis.
    case delete
    /// The hypothesis has an extra word not in the reference.
    case insert
}

/// A single aligned token pair in the WER diff. Exactly one of `reference` /
/// `hypothesis` is nil for `.delete` / `.insert`; both are set for `.equal` and
/// `.substitute`. This is what the Engine Lab renders as colored word chips.
public struct DiffToken: Equatable, Sendable, Identifiable {
    public let id: Int
    public let op: DiffOp
    /// The reference word at this step (nil for a pure insertion).
    public let reference: String?
    /// The hypothesis word at this step (nil for a pure deletion).
    public let hypothesis: String?

    public init(id: Int, op: DiffOp, reference: String?, hypothesis: String?) {
        self.id = id
        self.op = op
        self.reference = reference
        self.hypothesis = hypothesis
    }
}

/// The full result of scoring one hypothesis against one reference.
public struct WERResult: Equatable, Sendable {
    /// Substitutions in the optimal alignment.
    public let substitutions: Int
    /// Deletions (reference words the hypothesis dropped).
    public let deletions: Int
    /// Insertions (extra hypothesis words not in the reference).
    public let insertions: Int
    /// Correctly matched words.
    public let hits: Int
    /// Number of words in the reference (the WER denominator).
    public let referenceWordCount: Int
    /// The aligned token stream (for the highlighted diff view).
    public let tokens: [DiffToken]

    public init(
        substitutions: Int,
        deletions: Int,
        insertions: Int,
        hits: Int,
        referenceWordCount: Int,
        tokens: [DiffToken]
    ) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.hits = hits
        self.referenceWordCount = referenceWordCount
        self.tokens = tokens
    }

    /// Total edit distance = S + D + I.
    public var editDistance: Int { substitutions + deletions + insertions }

    /// Word Error Rate in the range 0…(unbounded). Standard definition:
    /// `(S + D + I) / N` where N is the reference word count.
    ///
    /// Edge cases, defined so the UI never shows NaN:
    /// - empty reference AND empty hypothesis → 0 (perfect: nothing to get wrong);
    /// - empty reference but non-empty hypothesis → 1.0 per inserted word is
    ///   undefined by the /N formula (N = 0), so we report `1.0` (100%) when there
    ///   is any hypothesis output against an empty reference, and `0` when both are
    ///   empty. This keeps a silence fixture (empty reference) honest: any spurious
    ///   words score as a full error rather than dividing by zero.
    public var wer: Double {
        if referenceWordCount == 0 {
            return insertions == 0 ? 0 : 1.0
        }
        return Double(editDistance) / Double(referenceWordCount)
    }

    /// WER as a rounded percentage string, e.g. "4.2%". One decimal place — enough
    /// to distinguish engines without implying false precision.
    public var werPercentString: String {
        String(format: "%.1f%%", wer * 100)
    }
}

/// Word Error Rate + word-level diff calculator. Stateless; call `score`.
public enum WordErrorRate {

    /// Score `hypothesis` against `reference`, returning counts + an aligned diff.
    ///
    /// - Parameters:
    ///   - reference: the known-correct transcript (the fixture's `.txt`).
    ///   - hypothesis: an engine's output.
    ///   - normalization: how to tokenize/canonicalize before aligning. WER is
    ///     conventionally computed on normalized text (lowercased, punctuation
    ///     stripped) so "Dog." vs "dog" isn't counted as an error — the Engine Lab
    ///     wants recognition accuracy, not punctuation nitpicks. Pass `.raw` to
    ///     score verbatim.
    public static func score(
        reference: String,
        hypothesis: String,
        normalization: Normalization = .standard
    ) -> WERResult {
        let refWords = tokenize(reference, normalization: normalization)
        let hypWords = tokenize(hypothesis, normalization: normalization)
        return align(reference: refWords, hypothesis: hypWords)
    }

    // MARK: - Normalization

    public struct Normalization: Equatable, Sendable {
        public var lowercase: Bool
        public var stripPunctuation: Bool
        /// Collapse runs of whitespace and trim — always on; kept explicit for docs.
        public var collapseWhitespace: Bool

        public init(lowercase: Bool, stripPunctuation: Bool, collapseWhitespace: Bool = true) {
            self.lowercase = lowercase
            self.stripPunctuation = stripPunctuation
            self.collapseWhitespace = collapseWhitespace
        }

        /// The Engine Lab default: case-insensitive, punctuation-insensitive — the
        /// standard "did it recognize the WORDS" comparison.
        public static let standard = Normalization(lowercase: true, stripPunctuation: true)
        /// Verbatim scoring (case- and punctuation-sensitive).
        public static let raw = Normalization(lowercase: false, stripPunctuation: false)
    }

    /// Split text into comparison tokens under a normalization. Unicode-aware
    /// (`unicodeScalars`/`CharacterSet`) so Cyrillic, accented Latin, etc. tokenize
    /// correctly — critical for the multilingual fixtures that are the whole point.
    static func tokenize(_ text: String, normalization: Normalization) -> [String] {
        var s = text
        if normalization.lowercase {
            s = s.lowercased()
        }
        // Split on whitespace/newlines first.
        let rawTokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard normalization.stripPunctuation else {
            return rawTokens.filter { !$0.isEmpty }
        }
        // Strip leading/trailing punctuation & symbols from each token, keeping
        // intra-word marks (e.g. "don't" stays one token). Drop tokens that become
        // empty (a lone "—" or ".").
        var out: [String] = []
        out.reserveCapacity(rawTokens.count)
        for token in rawTokens {
            let cleaned = token.trimmingCharacters(in: Self.edgePunctuation)
            if !cleaned.isEmpty { out.append(cleaned) }
        }
        return out
    }

    private static let edgePunctuation: CharacterSet = {
        var set = CharacterSet.punctuationCharacters
        set.formUnion(.symbols)
        return set
    }()

    // MARK: - Alignment (Wagner–Fischer with backtrace)

    /// Minimum-edit alignment of two word arrays. Returns the S/D/I/hit counts AND
    /// the aligned diff token stream, derived from the same backtrace so they agree.
    static func align(reference: [String], hypothesis: [String]) -> WERResult {
        let n = reference.count
        let m = hypothesis.count

        // dp[i][j] = edit distance between reference[0..<i] and hypothesis[0..<j].
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }   // delete all reference words
        for j in 0...m { dp[0][j] = j }   // insert all hypothesis words

        for i in 1...max(n, 1) where n >= 1 {
            for j in 1...max(m, 1) where m >= 1 {
                if reference[i - 1] == hypothesis[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    let sub = dp[i - 1][j - 1] + 1
                    let del = dp[i - 1][j] + 1
                    let ins = dp[i][j - 1] + 1
                    dp[i][j] = min(sub, min(del, ins))
                }
            }
        }

        // Backtrace from (n, m) to (0, 0), preferring substitution/equal on the
        // diagonal so the diff reads naturally.
        var tokens: [DiffToken] = []
        var i = n
        var j = m
        var subs = 0, dels = 0, inss = 0, hits = 0
        var nextID = 0

        func push(_ op: DiffOp, _ ref: String?, _ hyp: String?) {
            tokens.append(DiffToken(id: nextID, op: op, reference: ref, hypothesis: hyp))
            nextID += 1
        }

        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1], dp[i][j] == dp[i - 1][j - 1] {
                push(.equal, reference[i - 1], hypothesis[j - 1]); hits += 1
                i -= 1; j -= 1
            } else if i > 0, j > 0, dp[i][j] == dp[i - 1][j - 1] + 1 {
                push(.substitute, reference[i - 1], hypothesis[j - 1]); subs += 1
                i -= 1; j -= 1
            } else if i > 0, dp[i][j] == dp[i - 1][j] + 1 {
                push(.delete, reference[i - 1], nil); dels += 1
                i -= 1
            } else {
                // j > 0 must hold here (either i == 0, or the insert branch is optimal).
                push(.insert, nil, hypothesis[j - 1]); inss += 1
                j -= 1
            }
        }

        tokens.reverse()
        // Re-key ids in forward order so `Identifiable` order matches display order.
        let ordered = tokens.enumerated().map { index, t in
            DiffToken(id: index, op: t.op, reference: t.reference, hypothesis: t.hypothesis)
        }

        return WERResult(
            substitutions: subs,
            deletions: dels,
            insertions: inss,
            hits: hits,
            referenceWordCount: n,
            tokens: ordered
        )
    }
}
