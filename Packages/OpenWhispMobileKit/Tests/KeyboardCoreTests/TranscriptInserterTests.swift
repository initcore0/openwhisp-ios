import XCTest
@testable import KeyboardCore
import MobileCore

/// The insert-path gate (ARCHITECTURE §5/§7, WP4 deliverable 5): drive the REAL
/// `TranscriptInserter` + real `TranscriptInsertPolicy` + a real tempdir
/// `AppGroupHandoffStore` through a fake sink, proving the four invariants:
/// exactly-once insert, no insert into a secure field, no insert when expired,
/// and correct spacing after existing text.
final class TranscriptInserterTests: XCTestCase {

    // MARK: - Fake sink

    /// An in-memory `KeyboardTextSink` that records inserts and lets a test set the
    /// caret context, secure-field flag, and Full-Access flag.
    private final class FakeSink: KeyboardTextSink {
        var inserted: [String] = []
        var deletions: [Int] = []
        var contextBeforeCaret: String?
        var returnKeyLabel: ReturnKeyLabel = .return
        var isSecureField: Bool = false
        var hasFullAccess: Bool = true

        init(context: String? = nil) { self.contextBeforeCaret = context }

        func insert(_ text: String) {
            inserted.append(text)
            // Mirror the real proxy so contextBeforeCaret reflects prior inserts —
            // makes a second call's spacing decision realistic.
            contextBeforeCaret = (contextBeforeCaret ?? "") + text
        }
        func deleteBackward(_ count: Int) { deletions.append(count) }
    }

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func makeStore() throws -> AppGroupHandoffStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inserter-\(UUID().uuidString)", isDirectory: true)
        return try AppGroupHandoffStore(directory: dir)
    }

    private func fresh(id: UUID = UUID(), text: String) -> PendingTranscript {
        PendingTranscript(id: id, text: text, createdAt: now, source: .appIntent)
    }

    private func expired(id: UUID = UUID(), text: String) -> PendingTranscript {
        PendingTranscript(id: id, text: text, createdAt: now.addingTimeInterval(-200), source: .appIntent)
    }

    // MARK: - Exactly-once insert

    func testExactlyOnceInsert() throws {
        let store = try makeStore()
        let id = UUID()
        try store.publish(fresh(id: id, text: "hello"))

        let sink = FakeSink(context: nil)
        let inserter = TranscriptInserter()

        // At an empty field the policy capitalizes the first letter (sentence start).
        let first = try inserter.insert(id: id, from: store, into: sink, now: now)
        XCTAssertEqual(first, .inserted("Hello"))
        XCTAssertEqual(sink.inserted, ["Hello"])

        // Second attempt for the SAME id finds nothing — the atomic consume emptied
        // the mailbox. No double-insert (R0c idempotency).
        let second = try inserter.insert(id: id, from: store, into: sink, now: now)
        XCTAssertEqual(second, .nothingPending)
        XCTAssertEqual(sink.inserted, ["Hello"], "must not insert twice")
    }

    // MARK: - No insert into a secure field

    func testRefusesSecureField() throws {
        let store = try makeStore()
        let id = UUID()
        try store.publish(fresh(id: id, text: "secret"))

        let sink = FakeSink(context: nil)
        sink.isSecureField = true

        let outcome = try TranscriptInserter().insert(id: id, from: store, into: sink, now: now)
        XCTAssertEqual(outcome, .refused)
        XCTAssertTrue(sink.inserted.isEmpty, "must never insert into a password field")

        // The slot was consumed (destroyed) — a refused transcript does not linger.
        XCTAssertNil(try store.peek())
    }

    // MARK: - No insert when expired

    func testRefusesExpired() throws {
        let store = try makeStore()
        let id = UUID()
        try store.publish(expired(id: id, text: "stale"))

        let sink = FakeSink(context: nil)
        let outcome = try TranscriptInserter().insert(id: id, from: store, into: sink, now: now)

        // The store's consume already refuses an expired transcript (returns nil),
        // so from the inserter's view there was nothing to take.
        XCTAssertEqual(outcome, .nothingPending)
        XCTAssertTrue(sink.inserted.isEmpty, "must never insert an expired transcript")
        XCTAssertNil(try store.peek(), "expired transcript is destroyed, not left pending")
    }

    // MARK: - Correct spacing after existing text

    func testSpacingAfterExistingWord() throws {
        let store = try makeStore()
        let id = UUID()
        try store.publish(fresh(id: id, text: "world"))

        // Caret sits right after "Hello" with no trailing space → a space is added.
        let sink = FakeSink(context: "Hello")
        let outcome = try TranscriptInserter().insert(id: id, from: store, into: sink, now: now)
        XCTAssertEqual(outcome, .inserted(" world"))
        XCTAssertEqual(sink.inserted, [" world"])
    }

    func testSpacingAfterTrailingSpaceNotDoubled() throws {
        let store = try makeStore()
        let id = UUID()
        try store.publish(fresh(id: id, text: "world"))

        let sink = FakeSink(context: "Hello ")   // already ends in a space
        let outcome = try TranscriptInserter().insert(id: id, from: store, into: sink, now: now)
        XCTAssertEqual(outcome, .inserted("world"), "no double space")
    }

    func testCapitalizesAtSentenceStart() throws {
        let store = try makeStore()
        let id = UUID()
        try store.publish(fresh(id: id, text: "next sentence."))

        let sink = FakeSink(context: "Done. ")   // sentence boundary
        let outcome = try TranscriptInserter().insert(id: id, from: store, into: sink, now: now)
        XCTAssertEqual(outcome, .inserted("Next sentence."))
    }

    // MARK: - Wrong id never consumes the pending one

    func testWrongIdLeavesPending() throws {
        let store = try makeStore()
        let realID = UUID()
        try store.publish(fresh(id: realID, text: "keep me"))

        let sink = FakeSink(context: nil)
        let outcome = try TranscriptInserter().insert(id: UUID(), from: store, into: sink, now: now)
        XCTAssertEqual(outcome, .nothingPending)
        XCTAssertTrue(sink.inserted.isEmpty)
        // The real transcript is untouched and still insertable.
        XCTAssertEqual(try store.peek()?.id, realID)
        // Empty field → first letter capitalized by the policy (sentence start).
        XCTAssertEqual(try TranscriptInserter().insert(id: realID, from: store, into: sink, now: now),
                       .inserted("Keep me"))
    }
}
