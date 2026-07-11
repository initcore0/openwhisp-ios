import XCTest
@testable import MobileCore

/// The file-based store must satisfy the exact contract `InMemoryHandoffStore`
/// models (its doc comment says so) — these tests mirror that suite against a
/// real temp directory, plus file-only concerns (racing claims, restore).
final class AppGroupHandoffStoreTests: XCTestCase {

    private var dir: URL!
    private var store: AppGroupHandoffStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-tests-\(UUID().uuidString)", isDirectory: true)
        store = try AppGroupHandoffStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func transcript(
        _ text: String = "Hello.",
        createdAt: Date = Date(timeIntervalSince1970: 1000)
    ) -> PendingTranscript {
        PendingTranscript(text: text, createdAt: createdAt, source: .inApp)
    }

    // MARK: contract parity with InMemoryHandoffStore

    func testPublishThenPeekRoundTrips() throws {
        let t = transcript()
        try store.publish(t)
        XCTAssertEqual(try store.peek(), t)
    }

    func testConsumeSucceedsExactlyOnce() throws {
        let t = transcript()
        try store.publish(t)
        let now = t.createdAt.addingTimeInterval(1)
        XCTAssertEqual(try store.consume(id: t.id, now: now), t)
        XCTAssertNil(try store.consume(id: t.id, now: now), "second consume must be nil")
        XCTAssertNil(try store.peek(), "consume empties the mailbox")
    }

    func testConsumeExpiredReturnsNilAndEmptiesTheSlot() throws {
        let t = transcript()
        try store.publish(t)
        let late = t.expiresAt.addingTimeInterval(1)
        XCTAssertNil(try store.consume(id: t.id, now: late))
        XCTAssertNil(try store.peek(), "an expired transcript must be destroyed, not linger")
    }

    func testConsumeWithStaleIdPreservesTheNewerPending() throws {
        let old = transcript("old")
        let new = transcript("new")
        try store.publish(old)
        try store.publish(new)          // replaces old
        let now = new.createdAt.addingTimeInterval(1)
        XCTAssertNil(try store.consume(id: old.id, now: now), "stale id must not consume")
        XCTAssertEqual(try store.peek(), new, "the newer transcript must survive a stale-id consume")
        XCTAssertEqual(try store.consume(id: new.id, now: now), new)
    }

    func testPublishReplacesThePendingTranscript() throws {
        let a = transcript("a")
        let b = transcript("b")
        try store.publish(a)
        try store.publish(b)
        XCTAssertEqual(try store.peek(), b)
        XCTAssertNil(try store.consume(id: a.id, now: a.createdAt), "replaced transcript is gone")
    }

    func testDiscardAllEmptiesTheMailbox() throws {
        try store.publish(transcript())
        try store.discardAll()
        XCTAssertNil(try store.peek())
    }

    func testConsumeOnEmptyStoreIsNil() throws {
        XCTAssertNil(try store.consume(id: UUID(), now: Date()))
    }

    // MARK: file-only concerns

    func testRacingConsumersExactlyOneWins() throws {
        let t = transcript()
        try store.publish(t)
        let now = t.createdAt.addingTimeInterval(1)

        let winners = NSMutableArray()  // NSMutableArray is thread-safe enough with the lock below
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if let got = (try? self.store.consume(id: t.id, now: now)) ?? nil {
                lock.lock(); winners.add(got); lock.unlock()
            }
        }
        XCTAssertEqual(winners.count, 1, "exactly one racing consumer may win")
        XCTAssertEqual(winners.firstObject as? PendingTranscript, t)
    }

    func testCorruptPendingFileIsHandledAsEmpty() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("pending.json"))
        XCTAssertNil(try store.peek())
        XCTAssertNil(try store.consume(id: UUID(), now: Date()))
    }

    // MARK: notifier + shared state

    func testDarwinNotifierDeliversInProcess() {
        let notifier = DarwinHandoffNotifier()
        let got = expectation(description: "onPublished fired")
        notifier.onPublished = { got.fulfill() }
        notifier.notifyPublished()
        wait(for: [got], timeout: 2)
    }

    func testSharedStateRoundTripsAndDefaultsWhenCorrupt() throws {
        let shared = try FileSharedStateStore(directory: dir)
        XCTAssertEqual(shared.readCaptureState(), .idle, "missing file → idle")
        XCTAssertEqual(shared.readKeyboardConfig(), .default)

        shared.writeCaptureState(.capturing)
        var config = KeyboardConfig.default
        config.mode = "email"
        config.autocap = false
        shared.writeKeyboardConfig(config)

        let reread = try FileSharedStateStore(directory: dir)
        XCTAssertEqual(reread.readCaptureState(), .capturing)
        XCTAssertEqual(reread.readKeyboardConfig(), config)

        try Data("garbage".utf8).write(to: dir.appendingPathComponent("shared-state.json"))
        XCTAssertEqual(reread.readCaptureState(), .idle, "corrupt file → safe defaults")
    }
}
