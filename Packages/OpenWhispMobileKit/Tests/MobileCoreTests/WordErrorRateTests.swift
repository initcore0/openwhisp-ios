import XCTest
@testable import MobileCore

/// Exhaustive tests for the Engine Lab's WER + word-diff util. This is the number
/// the whole "better than Apple" claim rests on, so it is pinned hard: known
/// alignments, the standard S/D/I definition, Unicode (multilingual) tokenization,
/// and every edge case the UI must not crash on (empty reference, empty hypothesis,
/// silence fixture).
final class WordErrorRateTests: XCTestCase {

    // MARK: - Perfect match

    func testIdenticalIsZeroWER() {
        let r = WordErrorRate.score(reference: "the quick brown fox", hypothesis: "the quick brown fox")
        XCTAssertEqual(r.wer, 0)
        XCTAssertEqual(r.hits, 4)
        XCTAssertEqual(r.editDistance, 0)
        XCTAssertEqual(r.referenceWordCount, 4)
        XCTAssertTrue(r.tokens.allSatisfy { $0.op == .equal })
    }

    func testCaseAndPunctuationIgnoredByDefault() {
        // "Dog." vs "dog" must NOT count as an error under standard normalization.
        let r = WordErrorRate.score(
            reference: "The quick brown Fox.",
            hypothesis: "the quick brown fox"
        )
        XCTAssertEqual(r.wer, 0, "standard normalization should ignore case + trailing punctuation")
    }

    func testRawNormalizationCountsCaseAndPunctuation() {
        let r = WordErrorRate.score(
            reference: "The Fox.",
            hypothesis: "the fox",
            normalization: .raw
        )
        // "The"→"the" and "Fox."→"fox" are both substitutions verbatim.
        XCTAssertEqual(r.substitutions, 2)
        XCTAssertEqual(r.wer, 1.0)
    }

    // MARK: - Single-op alignments

    func testOneSubstitution() {
        let r = WordErrorRate.score(reference: "the quick brown fox", hypothesis: "the slow brown fox")
        XCTAssertEqual(r.substitutions, 1)
        XCTAssertEqual(r.deletions, 0)
        XCTAssertEqual(r.insertions, 0)
        XCTAssertEqual(r.wer, 0.25, accuracy: 1e-9)
    }

    func testOneDeletion() {
        // Hypothesis dropped a reference word.
        let r = WordErrorRate.score(reference: "the quick brown fox", hypothesis: "the brown fox")
        XCTAssertEqual(r.deletions, 1)
        XCTAssertEqual(r.substitutions, 0)
        XCTAssertEqual(r.insertions, 0)
        XCTAssertEqual(r.wer, 0.25, accuracy: 1e-9)
    }

    func testOneInsertion() {
        // Hypothesis added an extra word.
        let r = WordErrorRate.score(reference: "the brown fox", hypothesis: "the quick brown fox")
        XCTAssertEqual(r.insertions, 1)
        XCTAssertEqual(r.substitutions, 0)
        XCTAssertEqual(r.deletions, 0)
        // N = 3 reference words → 1/3.
        XCTAssertEqual(r.wer, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testMixedErrors() {
        // ref: a b c d e   (5 words)
        // hyp: a x c e f   → b→x sub, d deleted, f inserted (relative to e/f tail)
        let r = WordErrorRate.score(reference: "a b c d e", hypothesis: "a x c e f")
        XCTAssertEqual(r.referenceWordCount, 5)
        // Optimal edits: sub(b→x), del(d), ins(f) = 3.
        XCTAssertEqual(r.editDistance, 3)
        XCTAssertEqual(r.wer, 0.6, accuracy: 1e-9)
    }

    // MARK: - Edge cases (must not divide by zero / crash)

    func testBothEmptyIsPerfect() {
        let r = WordErrorRate.score(reference: "", hypothesis: "")
        XCTAssertEqual(r.wer, 0)
        XCTAssertEqual(r.referenceWordCount, 0)
        XCTAssertTrue(r.tokens.isEmpty)
    }

    func testEmptyReferenceWithOutputIsFullError() {
        // Silence fixture (empty reference): any spurious words = 100% error, not NaN.
        let r = WordErrorRate.score(reference: "", hypothesis: "hello there")
        XCTAssertEqual(r.insertions, 2)
        XCTAssertEqual(r.wer, 1.0)
        XCTAssertFalse(r.wer.isNaN)
    }

    func testEmptyHypothesisIsAllDeletions() {
        let r = WordErrorRate.score(reference: "one two three", hypothesis: "")
        XCTAssertEqual(r.deletions, 3)
        XCTAssertEqual(r.wer, 1.0)
    }

    // MARK: - Unicode / multilingual (the whole point)

    func testCyrillicTokenization() {
        // Russian reference vs a one-word error. Cyrillic must tokenize by word.
        let ref = "Здравствуйте меня зовут Иван"
        let hyp = "Здравствуйте меня зовут Иван"
        let perfect = WordErrorRate.score(reference: ref, hypothesis: hyp)
        XCTAssertEqual(perfect.wer, 0, "identical Cyrillic should be 0% WER")

        let oneOff = WordErrorRate.score(reference: ref, hypothesis: "Здравствуйте меня зовут Пётр")
        XCTAssertEqual(oneOff.substitutions, 1)
        XCTAssertEqual(oneOff.referenceWordCount, 4)
        XCTAssertEqual(oneOff.wer, 0.25, accuracy: 1e-9)
    }

    func testAccentedLatinPunctuationStripping() {
        // French with an apostrophe + trailing punctuation.
        let r = WordErrorRate.score(
            reference: "Bonjour, je m'appelle Marie.",
            hypothesis: "bonjour je m'appelle marie"
        )
        // "m'appelle" must survive as ONE token (intra-word apostrophe kept).
        XCTAssertEqual(r.wer, 0, "intra-word apostrophe kept; edge punctuation stripped")
    }

    // MARK: - Diff token stream consistency

    func testDiffTokensReconstructReference() {
        let r = WordErrorRate.score(reference: "a b c d e", hypothesis: "a x c e f")
        // Reference words appear in order across equal+substitute+delete tokens.
        let refBack = r.tokens.compactMap { $0.op == .insert ? nil : $0.reference }
        XCTAssertEqual(refBack, ["a", "b", "c", "d", "e"])
        // Hypothesis words appear in order across equal+substitute+insert tokens.
        let hypBack = r.tokens.compactMap { $0.op == .delete ? nil : $0.hypothesis }
        XCTAssertEqual(hypBack, ["a", "x", "c", "e", "f"])
    }

    func testCountsMatchTokenOps() {
        let r = WordErrorRate.score(reference: "a b c d e", hypothesis: "a x c e f")
        let subs = r.tokens.filter { $0.op == .substitute }.count
        let dels = r.tokens.filter { $0.op == .delete }.count
        let inss = r.tokens.filter { $0.op == .insert }.count
        let eqs = r.tokens.filter { $0.op == .equal }.count
        XCTAssertEqual(subs, r.substitutions)
        XCTAssertEqual(dels, r.deletions)
        XCTAssertEqual(inss, r.insertions)
        XCTAssertEqual(eqs, r.hits)
    }

    func testTokenIDsAreForwardOrdered() {
        let r = WordErrorRate.score(reference: "one two three", hypothesis: "one three")
        XCTAssertEqual(r.tokens.map(\.id), Array(0..<r.tokens.count))
    }

    // MARK: - Formatting

    func testPercentStringFormatting() {
        let r = WordErrorRate.score(reference: "a b c d", hypothesis: "a b c x")
        XCTAssertEqual(r.werPercentString, "25.0%")
    }
}
