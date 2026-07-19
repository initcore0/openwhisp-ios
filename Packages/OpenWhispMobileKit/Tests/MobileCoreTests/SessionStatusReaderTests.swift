import XCTest
@testable import MobileCore

/// The WP10c session-status reader seam: the file-backed conformer reading
/// `session/status.json` (agreed path/format with the WP10b writer) and the
/// in-memory double. Reader-only — no file is created when none exists.
final class SessionStatusReaderTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - File reader

    func testMissingFileReadsAsFreshOff() {
        let reader = AppGroupSessionStatusReader(directory: dir)
        let now = Date()
        let status = reader.read(now: now)
        XCTAssertEqual(status.phase, .off)
        XCTAssertEqual(status.effectivePhase(now: now), .off)
        // Reader must not have created the file (it only reads).
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("status.json").path))
    }

    func testReadsWrittenStatus() throws {
        let armedAt = Date()
        let written = SessionStatus(phase: .armed, sessionID: UUID(), armedAt: armedAt,
                                    expiresAt: armedAt.addingTimeInterval(300), updatedAt: armedAt)
        let data = try JSONEncoder().encode(written)
        try data.write(to: dir.appendingPathComponent("status.json"))

        let reader = AppGroupSessionStatusReader(directory: dir)
        let read = reader.read(now: armedAt)
        XCTAssertEqual(read, written)
        XCTAssertEqual(read.effectivePhase(now: armedAt), .armed)
    }

    func testStalePhaseCollapsesToOffViaEffectivePhase() throws {
        let old = Date().addingTimeInterval(-120)   // > 30 s staleness window
        let written = SessionStatus(phase: .capturing, sessionID: UUID(), armedAt: old,
                                    expiresAt: nil, updatedAt: old)
        try JSONEncoder().encode(written).write(to: dir.appendingPathComponent("status.json"))

        let reader = AppGroupSessionStatusReader(directory: dir)
        let now = Date()
        // The raw read still reports the file's phase; the fence lives in effectivePhase.
        XCTAssertEqual(reader.read(now: now).phase, .capturing)
        XCTAssertEqual(reader.read(now: now).effectivePhase(now: now), .off,
                       "a stale live phase must collapse to off — dead host never drives the key")
    }

    func testCorruptFileReadsAsOff() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("status.json"))
        let reader = AppGroupSessionStatusReader(directory: dir)
        XCTAssertEqual(reader.read(now: Date()).phase, .off)
    }

    // MARK: - In-memory double

    func testInMemoryDoubleDefaultsOff() {
        let reader = InMemorySessionStatusReader()
        XCTAssertEqual(reader.read(now: Date()).phase, .off)
    }

    func testInMemoryDoubleSetAndRead() {
        let reader = InMemorySessionStatusReader()
        let now = Date()
        reader.set(SessionStatus(phase: .capturing, sessionID: UUID(), armedAt: now,
                                 expiresAt: nil, updatedAt: now))
        XCTAssertEqual(reader.read(now: now).effectivePhase(now: now), .capturing)
    }
}
