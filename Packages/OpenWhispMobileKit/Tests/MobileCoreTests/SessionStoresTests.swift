import XCTest
@testable import MobileCore

/// The file-based session stores must satisfy the exact contract their in-memory
/// doubles model — these tests run both the doubles and the real temp-directory
/// stores through the same suite, plus file-only concerns (racing takes, corrupt
/// files), mirroring `AppGroupHandoffStoreTests`.
final class SessionStoresTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Command mailbox: contract parity (double + file store)

    private func eachMailbox(_ body: (SessionCommandMailbox) throws -> Void) throws {
        try body(InMemorySessionCommandMailbox())
        try body(try AppGroupSessionCommandMailbox(directory: dir.appendingPathComponent(UUID().uuidString)))
    }

    func testPostThenTakeRoundTrips() throws {
        try eachMailbox { mb in
            try mb.post(.startCapture, now: t0)
            XCTAssertEqual(try mb.take(now: t0.addingTimeInterval(1)), .startCapture)
        }
    }

    func testTakeSucceedsExactlyOnce() throws {
        try eachMailbox { mb in
            try mb.post(.stopCapture, now: t0)
            XCTAssertEqual(try mb.take(now: t0), .stopCapture)
            XCTAssertNil(try mb.take(now: t0), "second take must be nil")
        }
    }

    func testPostReplacesThePendingCommand() throws {
        try eachMailbox { mb in
            try mb.post(.startCapture, now: t0)
            try mb.post(.endSession, now: t0)
            XCTAssertEqual(try mb.take(now: t0), .endSession, "the newest post wins")
        }
    }

    func testExpiredCommandIsDestroyedNotDelivered() throws {
        try eachMailbox { mb in
            try mb.post(.startCapture, now: t0)
            let late = t0.addingTimeInterval(sessionCommandExpiry + 1)
            XCTAssertNil(try mb.take(now: late), "a stale startCapture must never fire")
            XCTAssertNil(try mb.take(now: t0), "and the slot is emptied by the expired take")
        }
    }

    func testExactlyAtExpiryStillDelivers() throws {
        try eachMailbox { mb in
            try mb.post(.startCapture, now: t0)
            // isExpired uses > (strict), so exactly at the boundary is still live.
            XCTAssertEqual(try mb.take(now: t0.addingTimeInterval(sessionCommandExpiry)), .startCapture)
        }
    }

    func testTakeOnEmptyIsNil() throws {
        try eachMailbox { mb in
            XCTAssertNil(try mb.take(now: t0))
        }
    }

    // MARK: - Command mailbox: file-only concerns

    func testRacingTakesExactlyOneWins() throws {
        let mb = try AppGroupSessionCommandMailbox(directory: dir)
        try mb.post(.startCapture, now: t0)

        let winners = NSMutableArray()
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if let got = (try? mb.take(now: self.t0)) ?? nil {
                lock.lock(); winners.add(got.rawValue); lock.unlock()
            }
        }
        XCTAssertEqual(winners.count, 1, "exactly one racing take may win")
        XCTAssertEqual(winners.firstObject as? String, SessionCommand.startCapture.rawValue)
    }

    func testCorruptCommandFileIsHandledAsEmpty() throws {
        let sub = dir.appendingPathComponent(UUID().uuidString)
        let mb = try AppGroupSessionCommandMailbox(directory: sub)
        try Data("not json".utf8).write(to: sub.appendingPathComponent("command.json"))
        XCTAssertNil(try mb.take(now: t0))
    }

    // MARK: - Live partial store: contract parity (double + file store)

    private func eachPartialStore(_ body: (LivePartialStore) throws -> Void) throws {
        try body(InMemoryLivePartialStore())
        try body(try AppGroupLivePartialStore(directory: dir.appendingPathComponent(UUID().uuidString)))
    }

    private func partial(_ seq: Int, text: String = "hello", isFinal: Bool = false, captureID: UUID = UUID()) -> LivePartial {
        LivePartial(captureID: captureID, seq: seq, text: text, isFinal: isFinal, updatedAt: t0)
    }

    func testPartialWriteReadRoundTrips() throws {
        try eachPartialStore { store in
            let p = partial(1)
            try store.write(p)
            XCTAssertEqual(try store.read(), p)
        }
    }

    func testPartialIsLastWriterWins() throws {
        try eachPartialStore { store in
            let cid = UUID()
            try store.write(partial(1, text: "he", captureID: cid))
            try store.write(partial(2, text: "hello", captureID: cid))
            let final = partial(3, text: "Hello.", isFinal: true, captureID: cid)
            try store.write(final)
            XCTAssertEqual(try store.read(), final, "the last write wins")
        }
    }

    func testPartialClearEmptiesTheSlot() throws {
        try eachPartialStore { store in
            try store.write(partial(1))
            try store.clear()
            XCTAssertNil(try store.read())
        }
    }

    func testReadOnEmptyPartialStoreIsNil() throws {
        try eachPartialStore { store in
            XCTAssertNil(try store.read())
        }
    }

    func testCorruptPartialFileIsHandledAsEmpty() throws {
        let sub = dir.appendingPathComponent(UUID().uuidString)
        let store = try AppGroupLivePartialStore(directory: sub)
        try Data("garbage".utf8).write(to: sub.appendingPathComponent("partial.json"))
        XCTAssertNil(try store.read())
    }

    // MARK: - Darwin names are the agreed constants

    func testDarwinNamesAreStable() {
        XCTAssertEqual(SessionDarwinNames.command, "app.openwhisp.session.command")
        XCTAssertEqual(SessionDarwinNames.partial, "app.openwhisp.session.partial")
        XCTAssertEqual(SessionDarwinNames.status, "app.openwhisp.session.status")
    }
}
