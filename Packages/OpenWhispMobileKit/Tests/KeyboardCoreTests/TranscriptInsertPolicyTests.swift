import XCTest
@testable import KeyboardCore
import MobileCore

/// Minimal fake sink so the pure policy can be exercised without UIKit.
private final class FakeSink: KeyboardTextSink {
    var context: String?
    var secure: Bool
    var fullAccess: Bool
    var label: ReturnKeyLabel

    init(context: String? = nil, secure: Bool = false, fullAccess: Bool = true, label: ReturnKeyLabel = .return) {
        self.context = context
        self.secure = secure
        self.fullAccess = fullAccess
        self.label = label
    }

    func insert(_ text: String) {}
    func deleteBackward(_ count: Int) {}
    var contextBeforeCaret: String? { context }
    var returnKeyLabel: ReturnKeyLabel { label }
    var isSecureField: Bool { secure }
    var hasFullAccess: Bool { fullAccess }
}

final class TranscriptInsertPolicyTests: XCTestCase {

    private let policy = TranscriptInsertPolicy()
    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func transcript(_ text: String, createdAt: Date? = nil) -> PendingTranscript {
        PendingTranscript(id: UUID(), text: text, createdAt: createdAt ?? now, source: .inApp)
    }

    // MARK: Permission — secure field refusal

    func testSecureFieldRefused() {
        let sink = FakeSink(secure: true)
        XCTAssertFalse(policy.permitted(transcript("hello"), sink: sink, now: now))
    }

    func testNonSecureFreshPermitted() {
        let sink = FakeSink(secure: false)
        XCTAssertTrue(policy.permitted(transcript("hello"), sink: sink, now: now))
    }

    // MARK: Permission — expiry refusal

    func testExpiredRefused() {
        let sink = FakeSink()
        let old = transcript("hello", createdAt: now.addingTimeInterval(-200))
        XCTAssertFalse(policy.permitted(old, sink: sink, now: now))
    }

    func testUnexpiredPermitted() {
        let sink = FakeSink()
        let t = transcript("hello")   // expiresAt = now + 120
        XCTAssertTrue(policy.permitted(t, sink: sink, now: now.addingTimeInterval(119)))
        XCTAssertFalse(policy.permitted(t, sink: sink, now: now.addingTimeInterval(120)))
    }

    func testSecureAndExpiredBothRefused() {
        let sink = FakeSink(secure: true)
        let old = transcript("hi", createdAt: now.addingTimeInterval(-200))
        XCTAssertFalse(policy.permitted(old, sink: sink, now: now))
    }

    // MARK: Rendering — empty transcript

    func testEmptyTranscriptRendersEmpty() {
        XCTAssertEqual(policy.rendered(transcript(""), context: "Hello"), "")
    }

    // MARK: Rendering — leading space

    func testLeadingSpaceAddedAfterWordCharacter() {
        // "Hello" + "world" → " world"
        XCTAssertEqual(policy.rendered(transcript("world"), context: "Hello"), " world")
    }

    func testNoLeadingSpaceAtFieldStart() {
        XCTAssertEqual(policy.rendered(transcript("hello"), context: nil), "Hello")
        XCTAssertEqual(policy.rendered(transcript("hello"), context: ""), "Hello")
    }

    func testNoLeadingSpaceWhenContextEndsInWhitespace() {
        XCTAssertEqual(policy.rendered(transcript("world"), context: "Hello "), "world")
    }

    func testNoLeadingSpaceWhenInsertionStartsWithClosingPunctuation() {
        // "Hello" + ", world" → ", world" (comma hugs the previous word)
        XCTAssertEqual(policy.rendered(transcript(", world"), context: "Hello"), ", world")
    }

    func testNoDoubleSpaceWhenInsertionStartsWithSpace() {
        XCTAssertEqual(policy.rendered(transcript(" world"), context: "Hello"), " world")
    }

    // MARK: Rendering — capitalization

    func testCapitalizeAtFieldStart() {
        XCTAssertEqual(policy.rendered(transcript("hello there"), context: nil), "Hello there")
    }

    func testCapitalizeAfterSentenceTerminator() {
        // "Done." + "next" → " Next"  (space added, N capitalized)
        XCTAssertEqual(policy.rendered(transcript("next thing"), context: "Done."), " Next thing")
    }

    func testCapitalizeAfterQuestionMark() {
        XCTAssertEqual(policy.rendered(transcript("yes"), context: "Ready? "), "Yes")
    }

    func testNoCapitalizeMidSentence() {
        // "I said" + "hello" → " hello" (lowercase kept mid-sentence)
        XCTAssertEqual(policy.rendered(transcript("hello"), context: "I said"), " hello")
    }

    func testMidSentenceKeepsOwnCasing() {
        // Host cleaner already cased proper nouns; policy leaves them alone.
        XCTAssertEqual(policy.rendered(transcript("iPhone stuff"), context: "my"), " iPhone stuff")
    }

    // MARK: Rendering — combined matrix (context × caps × spacing)

    func testCombinedMatrix() {
        struct Case { let context: String?; let text: String; let expected: String; let line: UInt }
        let cases: [Case] = [
            // field start: cap, no space
            Case(context: nil, text: "hi", expected: "Hi", line: #line),
            Case(context: "", text: "hi", expected: "Hi", line: #line),
            // mid word: no cap, leading space
            Case(context: "foo", text: "bar", expected: " bar", line: #line),
            // after terminator: cap + leading space
            Case(context: "End.", text: "start", expected: " Start", line: #line),
            // trailing whitespace context: no leading space; still not sentence start
            Case(context: "foo ", text: "bar", expected: "bar", line: #line),
            // trailing whitespace after terminator: cap, no leading space
            Case(context: "End. ", text: "go", expected: "Go", line: #line),
            // closing punctuation insertion hugs: no space, no cap of punctuation
            Case(context: "word", text: ". Next", expected: ". Next", line: #line),
        ]
        for c in cases {
            let got = policy.rendered(transcript(c.text), context: c.context)
            XCTAssertEqual(got, c.expected,
                           "context=\(String(describing: c.context)) text=\(c.text)",
                           line: c.line)
        }
    }
}
