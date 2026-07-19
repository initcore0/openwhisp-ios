import XCTest
@testable import MobileCore

/// The 30 s staleness rule, made explicit: `effectivePhase(now:)` collapses a
/// live phase whose heartbeat has lapsed to `.off` (never show a live mic key for
/// a dead host), and leaves fresh statuses alone.
final class SessionStatusTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func status(_ phase: SessionStatus.Phase, updatedAt: Date) -> SessionStatus {
        SessionStatus(phase: phase, sessionID: UUID(), armedAt: t0, expiresAt: nil, updatedAt: updatedAt)
    }

    func testFreshLivePhaseIsItself() {
        for phase in [SessionStatus.Phase.armed, .capturing, .transcribing] {
            let s = status(phase, updatedAt: t0)
            XCTAssertEqual(s.effectivePhase(now: t0.addingTimeInterval(10)), phase,
                           "\(phase) within the window stays itself")
        }
    }

    func testStaleLivePhaseCollapsesToOff() {
        for phase in [SessionStatus.Phase.armed, .capturing, .transcribing] {
            let s = status(phase, updatedAt: t0)
            let now = t0.addingTimeInterval(SessionStatus.stalenessWindow + 1)
            XCTAssertEqual(s.effectivePhase(now: now), .off, "stale \(phase) → off")
            XCTAssertTrue(s.isStale(now: now))
        }
    }

    func testExactlyAtWindowIsNotStale() {
        let s = status(.armed, updatedAt: t0)
        let now = t0.addingTimeInterval(SessionStatus.stalenessWindow)  // exactly 30 s
        XCTAssertFalse(s.isStale(now: now), "the boundary is inclusive (>, not >=)")
        XCTAssertEqual(s.effectivePhase(now: now), .armed)
    }

    func testOffStaysOffEvenWhenStale() {
        let s = SessionStatus.off(updatedAt: t0)
        let now = t0.addingTimeInterval(10_000)
        XCTAssertEqual(s.effectivePhase(now: now), .off)
    }

    func testFutureUpdatedAtIsNeverStale() {
        // Clock skew between processes: a status stamped slightly in our future.
        let s = status(.capturing, updatedAt: t0.addingTimeInterval(5))
        XCTAssertFalse(s.isStale(now: t0))
        XCTAssertEqual(s.effectivePhase(now: t0), .capturing)
    }

    func testCodableRoundTrip() throws {
        let s = SessionStatus(phase: .capturing, sessionID: UUID(), armedAt: t0,
                              expiresAt: t0.addingTimeInterval(300), updatedAt: t0)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SessionStatus.self, from: data), s)
    }

    func testIdleTimeoutIntervals() {
        XCTAssertEqual(DictationSessionConfig.IdleTimeout.fiveMinutes.interval, 300)
        XCTAssertEqual(DictationSessionConfig.IdleTimeout.fifteenMinutes.interval, 900)
        XCTAssertEqual(DictationSessionConfig.IdleTimeout.oneHour.interval, 3600)
        XCTAssertNil(DictationSessionConfig.IdleTimeout.never.interval)
    }
}
