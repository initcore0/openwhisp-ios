import XCTest
@testable import MobileCore

final class InMemoryHandoffStoreTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func makeTranscript(
        id: UUID = UUID(),
        text: String = "hello world",
        createdAt: Date? = nil,
        source: PendingTranscript.Source = .inApp
    ) -> PendingTranscript {
        PendingTranscript(id: id, text: text, createdAt: createdAt ?? base, source: source)
    }

    func testPublishThenPeekReturnsSameTranscript() throws {
        let store = InMemoryHandoffStore()
        let t = makeTranscript()
        try store.publish(t)
        XCTAssertEqual(try store.peek(), t)
        // Peek does not consume.
        XCTAssertEqual(try store.peek(), t)
    }

    func testPeekOnEmptyStoreReturnsNil() throws {
        let store = InMemoryHandoffStore()
        XCTAssertNil(try store.peek())
    }

    func testConsumeExactlyOnce() throws {
        let store = InMemoryHandoffStore()
        let t = makeTranscript()
        try store.publish(t)

        let first = try store.consume(id: t.id, now: base.addingTimeInterval(1))
        XCTAssertEqual(first, t)

        // Second consume of the same id gets nil — the mailbox is empty.
        let second = try store.consume(id: t.id, now: base.addingTimeInterval(1))
        XCTAssertNil(second)

        // And peek is now empty too.
        XCTAssertNil(try store.peek())
    }

    func testConsumeWithWrongIdReturnsNilAndLeavesTranscript() throws {
        let store = InMemoryHandoffStore()
        let t = makeTranscript()
        try store.publish(t)

        let wrong = try store.consume(id: UUID(), now: base.addingTimeInterval(1))
        XCTAssertNil(wrong)
        // The real transcript is still there.
        XCTAssertEqual(try store.peek(), t)
    }

    func testExpiredConsumeReturnsNilAndClearsSlot() throws {
        let store = InMemoryHandoffStore()
        let t = makeTranscript()          // expiresAt = base + 120
        try store.publish(t)

        // At exactly expiresAt it is expired (>=).
        let atExpiry = try store.consume(id: t.id, now: t.expiresAt)
        XCTAssertNil(atExpiry)
        // Expired consume clears the slot so nothing lingers.
        XCTAssertNil(try store.peek())
    }

    func testUnexpiredJustBeforeExpiryConsumes() throws {
        let store = InMemoryHandoffStore()
        let t = makeTranscript()
        try store.publish(t)
        let justBefore = t.expiresAt.addingTimeInterval(-0.001)
        XCTAssertEqual(try store.consume(id: t.id, now: justBefore), t)
    }

    func testPublishReplacesPreviousPending() throws {
        let store = InMemoryHandoffStore()
        let first = makeTranscript(text: "first")
        let second = makeTranscript(text: "second")
        try store.publish(first)
        try store.publish(second)
        XCTAssertEqual(try store.peek(), second)
        // Consuming the old id no longer works.
        XCTAssertNil(try store.consume(id: first.id, now: base.addingTimeInterval(1)))
    }

    func testDiscardAllEmptiesStore() throws {
        let store = InMemoryHandoffStore()
        try store.publish(makeTranscript())
        try store.discardAll()
        XCTAssertNil(try store.peek())
    }

    func testConcurrentConsumeYieldsExactlyOneWinner() throws {
        // Racing consumers: exactly one gets the transcript, everyone else nil.
        let store = InMemoryHandoffStore()
        let t = makeTranscript()
        try store.publish(t)

        let consumerCount = 64
        let results = NSMutableArray()
        let resultsLock = NSLock()
        let group = DispatchGroup()
        let now = base.addingTimeInterval(1)

        for _ in 0..<consumerCount {
            group.enter()
            DispatchQueue.global().async {
                let got = (try? store.consume(id: t.id, now: now)) ?? nil
                resultsLock.lock()
                if got != nil { results.add(1) }
                resultsLock.unlock()
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(results.count, 1, "exactly one racing consumer should win")
        XCTAssertNil(try store.peek())
    }

    func testPendingTranscriptExpiryHelper() {
        let t = makeTranscript()
        XCTAssertFalse(t.isExpired(now: base))
        XCTAssertFalse(t.isExpired(now: base.addingTimeInterval(119)))
        XCTAssertTrue(t.isExpired(now: base.addingTimeInterval(120)))
        XCTAssertTrue(t.isExpired(now: base.addingTimeInterval(121)))
    }

    func testPendingTranscriptCodableRoundTrip() throws {
        let t = makeTranscript(source: .appIntent)
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(PendingTranscript.self, from: data)
        XCTAssertEqual(decoded, t)
    }
}
