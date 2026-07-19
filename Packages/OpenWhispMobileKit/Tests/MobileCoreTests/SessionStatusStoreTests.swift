import XCTest
@testable import MobileCore

/// The session-status store (WP10b's sanctioned WP10a-gap fill): the host writes,
/// the keyboard reads, last-writer-wins. Runs the in-memory double AND the real
/// temp-directory store through the same contract, plus file-only concerns
/// (corrupt file → nil, clear removes), mirroring `SessionStoresTests`.
final class SessionStatusStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func eachStore(_ body: (SessionStatusStore) throws -> Void) throws {
        try body(InMemorySessionStatusStore())
        try body(try AppGroupSessionStatusStore(directory: dir.appendingPathComponent(UUID().uuidString)))
    }

    private func armed(at now: Date) -> SessionStatus {
        SessionStatus(phase: .armed, sessionID: UUID(), armedAt: now,
                      expiresAt: now.addingTimeInterval(300), updatedAt: now)
    }

    func testReadBeforeAnyWriteIsNil() throws {
        try eachStore { store in
            XCTAssertNil(try store.read())
        }
    }

    func testWriteThenReadRoundTrips() throws {
        try eachStore { store in
            let s = armed(at: t0)
            try store.write(s)
            XCTAssertEqual(try store.read(), s)
        }
    }

    func testLastWriterWins() throws {
        try eachStore { store in
            try store.write(armed(at: t0))
            let newer = SessionStatus(phase: .capturing, sessionID: UUID(), armedAt: t0,
                                      expiresAt: nil, updatedAt: t0.addingTimeInterval(5))
            try store.write(newer)
            XCTAssertEqual(try store.read()?.phase, .capturing)
            XCTAssertEqual(try store.read()?.updatedAt, t0.addingTimeInterval(5))
        }
    }

    func testClearRemovesStatus() throws {
        try eachStore { store in
            try store.write(armed(at: t0))
            try store.clear()
            XCTAssertNil(try store.read())
        }
    }

    // MARK: file-only

    func testCorruptFileReadsAsNil() throws {
        let sub = dir.appendingPathComponent("corrupt")
        let store = try AppGroupSessionStatusStore(directory: sub)
        try Data("not json".utf8).write(to: sub.appendingPathComponent("status.json"))
        XCTAssertNil(try store.read())
    }

    /// The reader folds in the 30 s staleness rule itself — a stale armed status the
    /// store faithfully returns still collapses to `.off` via `effectivePhase`.
    func testStoreReturnsFaithfully_ReaderAppliesStaleness() throws {
        let store = try AppGroupSessionStatusStore(directory: dir.appendingPathComponent("stale"))
        try store.write(armed(at: t0))
        let read = try XCTUnwrap(try store.read())
        XCTAssertEqual(read.phase, .armed)                                  // store is faithful
        XCTAssertEqual(read.effectivePhase(now: t0.addingTimeInterval(60)), .off) // reader is strict
    }
}
