import XCTest
@testable import KeyboardCore

/// Property cases for the pure live-insert differ. The invariant every case
/// asserts: applying the edit (delete `n` trailing CHARACTERS from `rendered`,
/// then append `insert`) reproduces `next` exactly. Grapheme correctness is the
/// point — `deleteBackward` counts what `UITextDocumentProxy.deleteBackward()`
/// removes: one `Character` per call.
final class LiveInsertDifferTests: XCTestCase {

    /// Simulate the proxy: delete `deleteBackward` grapheme clusters off the end,
    /// then append `insert`.
    private func apply(_ edit: (deleteBackward: Int, insert: String), to rendered: String) -> String {
        var chars = Array(rendered)
        chars.removeLast(edit.deleteBackward)
        return String(chars) + edit.insert
    }

    private func assertRoundTrips(from: String, to: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let edit = LiveInsertDiffer.edits(from: from, to: to)
        XCTAssertEqual(apply(edit, to: from), to,
                       "applying the edit must reproduce `to`", file: file, line: line)
    }

    // MARK: prefix growth → zero deletes, pure insert

    func testPrefixGrowth() {
        let edit = LiveInsertDiffer.edits(from: "hel", to: "hello")
        XCTAssertEqual(edit.deleteBackward, 0)
        XCTAssertEqual(edit.insert, "lo")
        assertRoundTrips(from: "hel", to: "hello")
    }

    func testFromEmpty() {
        let edit = LiveInsertDiffer.edits(from: "", to: "hello")
        XCTAssertEqual(edit.deleteBackward, 0)
        XCTAssertEqual(edit.insert, "hello")
    }

    // MARK: mid-string revision → delete diverging tail, insert new tail

    func testMidStringRevision() {
        // "hello wprld" → "hello world": common prefix "hello w", delete "prld"
        // (4 chars), insert "orld".
        let edit = LiveInsertDiffer.edits(from: "hello wprld", to: "hello world")
        XCTAssertEqual(edit.deleteBackward, 4)
        XCTAssertEqual(edit.insert, "orld")
        assertRoundTrips(from: "hello wprld", to: "hello world")
    }

    // MARK: shrink → delete only, empty insert

    func testShrink() {
        let edit = LiveInsertDiffer.edits(from: "hello there", to: "hello")
        XCTAssertEqual(edit.deleteBackward, 6)   // " there"
        XCTAssertEqual(edit.insert, "")
        assertRoundTrips(from: "hello there", to: "hello")
    }

    func testToEmpty() {
        let edit = LiveInsertDiffer.edits(from: "hello", to: "")
        XCTAssertEqual(edit.deleteBackward, 5)
        XCTAssertEqual(edit.insert, "")
    }

    // MARK: final swap → wholesale replacement when nothing shared

    func testFinalSwapWholesaleReplacement() {
        // raw partial replaced by cleaned final with no common prefix.
        let edit = LiveInsertDiffer.edits(from: "um hello", to: "Hello.")
        XCTAssertEqual(edit.deleteBackward, 8)
        XCTAssertEqual(edit.insert, "Hello.")
        assertRoundTrips(from: "um hello", to: "Hello.")
    }

    func testNoChange() {
        let edit = LiveInsertDiffer.edits(from: "same", to: "same")
        XCTAssertEqual(edit.deleteBackward, 0)
        XCTAssertEqual(edit.insert, "")
    }

    func testBothEmpty() {
        let edit = LiveInsertDiffer.edits(from: "", to: "")
        XCTAssertEqual(edit.deleteBackward, 0)
        XCTAssertEqual(edit.insert, "")
    }

    // MARK: emoji safety — one backspace per emoji, not per UTF-16 unit

    func testEmojiShrinkDeletesOnePerEmoji() {
        // Two emoji, each > 1 UTF-16 unit; removing the last must be ONE backspace.
        let edit = LiveInsertDiffer.edits(from: "hi 😀🎉", to: "hi 😀")
        XCTAssertEqual(edit.deleteBackward, 1, "one grapheme = one deleteBackward")
        XCTAssertEqual(edit.insert, "")
        assertRoundTrips(from: "hi 😀🎉", to: "hi 😀")
    }

    func testEmojiGrowth() {
        let edit = LiveInsertDiffer.edits(from: "hi 😀", to: "hi 😀🎉")
        XCTAssertEqual(edit.deleteBackward, 0)
        XCTAssertEqual(edit.insert, "🎉")
        assertRoundTrips(from: "hi 😀", to: "hi 😀🎉")
    }

    func testEmojiRevision() {
        // Swap the trailing emoji: common prefix "hi ", delete 1 (😀), insert 🎉.
        let edit = LiveInsertDiffer.edits(from: "hi 😀", to: "hi 🎉")
        XCTAssertEqual(edit.deleteBackward, 1)
        XCTAssertEqual(edit.insert, "🎉")
        assertRoundTrips(from: "hi 😀", to: "hi 🎉")
    }

    // MARK: ZWJ-sequence emoji (family) is a SINGLE grapheme cluster

    func testZWJFamilyEmojiIsOneGrapheme() {
        let family = "👨‍👩‍👧‍👦"   // multi-scalar ZWJ sequence, one Character
        XCTAssertEqual(family.count, 1, "sanity: family emoji is one grapheme cluster")
        let edit = LiveInsertDiffer.edits(from: "we \(family)", to: "we ")
        XCTAssertEqual(edit.deleteBackward, 1, "the whole ZWJ family deletes in ONE backspace")
        XCTAssertEqual(edit.insert, "")
        assertRoundTrips(from: "we \(family)", to: "we ")
    }

    // MARK: combining characters — base+mark is one grapheme cluster

    func testCombiningCharacterIsOneGrapheme() {
        // "e" + combining acute accent (U+0301) is one grapheme "é".
        let combined = "cafe\u{0301}"    // "café" as e + ´
        XCTAssertEqual(combined.count, 4, "sanity: 4 grapheme clusters despite 5 scalars")
        // "café" → "cafe": the trailing é (a base+mark grapheme cluster) differs
        // from the plain "e", so it deletes in ONE backspace and re-inserts "e" —
        // never a partial delete that would strip only the combining mark.
        let edit = LiveInsertDiffer.edits(from: combined, to: "cafe")
        XCTAssertEqual(edit.deleteBackward, 1, "the accented é deletes as ONE backspace")
        XCTAssertEqual(edit.insert, "e")
        assertRoundTrips(from: combined, to: "cafe")
    }

    func testCombiningMarkRemovalDeletesWholeCluster() {
        // Deleting ONLY the accent: "aé b" → "ae b" is still whole-cluster work.
        let edit = LiveInsertDiffer.edits(from: "ae\u{0301} b", to: "ae b")
        // common prefix "a", then diverge at the é vs e cluster.
        XCTAssertEqual(edit.deleteBackward, 3, "é + space + trailing char re-emitted")
        XCTAssertEqual(edit.insert, "e b")
        assertRoundTrips(from: "ae\u{0301} b", to: "ae b")
    }

    func testCombiningVsPrecomposedAreDifferentButBothOneGrapheme() {
        let decomposed = "e\u{0301}"     // e + combining acute
        let precomposed = "\u{00E9}"     // é
        // They are canonically equivalent; Swift String compares them equal.
        let edit = LiveInsertDiffer.edits(from: "a" + decomposed, to: "a" + precomposed)
        XCTAssertEqual(edit.deleteBackward, 0, "canonically-equal graphemes need no edit")
        XCTAssertEqual(edit.insert, "")
    }
}
