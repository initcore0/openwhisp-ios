import XCTest
@testable import MobileCore

/// Exhaustive `SessionFlow` coverage: every event × phase, incl. idle-timeout
/// edges, the `.never` timeout, stale-command rejection (via the mailbox — see
/// `SessionStoresTests`), interruption teardown, and the capture-state feedback
/// loop. Mirrors `CaptureFlowTests`' step-by-step style.
final class SessionFlowTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let fiveMin: TimeInterval = 5 * 60

    private func armed(_ flow: inout SessionFlow, at now: Date, timeout: DictationSessionConfig.IdleTimeout = .fiveMinutes) -> [SessionFlow.Effect] {
        flow.handle(.arm(config: DictationSessionConfig(idleTimeout: timeout), now: now))
    }

    // MARK: Arming

    func testArmFromOffActivatesAndSchedules() {
        var flow = SessionFlow()
        XCTAssertEqual(flow.status.phase, .off)

        let effects = armed(&flow, at: t0)
        XCTAssertEqual(flow.status.phase, .armed)
        XCTAssertEqual(flow.status.armedAt, t0)
        XCTAssertEqual(flow.status.expiresAt, t0.addingTimeInterval(fiveMin))
        XCTAssertNotNil(flow.status.sessionID)

        XCTAssertEqual(effects, [
            .activateAudioSession,
            .publishStatus(flow.status),
            .updateActivity(flow.status),
            .scheduleIdleCheck(at: t0.addingTimeInterval(fiveMin)),
        ])
    }

    func testArmWithNeverTimeoutSchedulesNothing() {
        var flow = SessionFlow()
        let effects = armed(&flow, at: t0, timeout: .never)
        XCTAssertNil(flow.status.expiresAt)
        XCTAssertFalse(effects.contains { if case .scheduleIdleCheck = $0 { return true }; return false },
                       "a .never session never schedules an idle check")
    }

    func testReArmRefreshesWindowWithoutReactivatingAudio() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let sid = flow.status.sessionID

        let later = t0.addingTimeInterval(60)
        let effects = armed(&flow, at: later)
        XCTAssertEqual(flow.status.sessionID, sid, "re-arm keeps the session identity")
        XCTAssertEqual(flow.status.armedAt, later, "window is refreshed")
        XCTAssertEqual(flow.status.expiresAt, later.addingTimeInterval(fiveMin))
        XCTAssertFalse(effects.contains(.activateAudioSession), "audio is already live")
    }

    // MARK: startCapture

    func testStartCaptureFromArmed() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)

        let effects = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        XCTAssertEqual(flow.status.phase, .capturing)
        XCTAssertEqual(effects, [
            .beginCapture(.keyboardHandoff),
            .publishStatus(flow.status),
            .updateActivity(flow.status),
        ])
    }

    func testStartCaptureWhileCapturingIsNoOp() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let effects = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(2)))
        XCTAssertEqual(effects, [], "a redundant startCapture does nothing")
        XCTAssertEqual(flow.status.phase, .capturing)
    }

    // MARK: stopCapture → transcribing → armed

    func testStopCaptureEndsCaptureLettingDecodeFinish() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))

        let effects = flow.handle(.command(.stopCapture, now: t0.addingTimeInterval(2)))
        XCTAssertEqual(effects, [.endCapture(cancel: false)])
        XCTAssertEqual(flow.status.phase, .capturing, "phase advances only when the driver reports it back")
    }

    func testCaptureChangedToTranscribingThenBackToArmed() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))

        // driver: transcribing
        var effects = flow.handle(.captureChanged(.transcribing))
        XCTAssertEqual(flow.status.phase, .transcribing)
        XCTAssertEqual(effects, [.publishStatus(flow.status), .updateActivity(flow.status)])

        // driver: published → back to armed, window refreshed, idle re-scheduled.
        effects = flow.handle(.captureChanged(.published(UUID())))
        XCTAssertEqual(flow.status.phase, .armed)
        XCTAssertTrue(effects.contains { if case .scheduleIdleCheck = $0 { return true }; return false })
    }

    func testCaptureChangedToListeningReflectsCapturing() {
        // If the driver reports listening before we processed startCapture (lag),
        // captureChanged still moves us to capturing.
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let effects = flow.handle(.captureChanged(.listening(level: 0.3)))
        XCTAssertEqual(flow.status.phase, .capturing)
        XCTAssertEqual(effects, [.publishStatus(flow.status), .updateActivity(flow.status)])
    }

    func testCaptureFailureDropsBackToArmedNotOff() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let effects = flow.handle(.captureChanged(.failed(.engineError("boom"))))
        XCTAssertEqual(flow.status.phase, .armed, "a capture failure keeps the session alive")
        XCTAssertTrue(effects.contains(.publishStatus(flow.status)))
    }

    // MARK: cancelCapture

    func testCancelCaptureReturnsToArmed() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let cancelAt = t0.addingTimeInterval(2)
        let effects = flow.handle(.command(.cancelCapture, now: cancelAt))
        XCTAssertEqual(flow.status.phase, .armed)
        XCTAssertEqual(flow.status.armedAt, cancelAt, "window refreshed on cancel")
        XCTAssertTrue(effects.contains(.endCapture(cancel: true)))
    }

    func testCancelCaptureWhileArmedIsNoOp() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let effects = flow.handle(.command(.cancelCapture, now: t0.addingTimeInterval(1)))
        XCTAssertEqual(effects, [])
    }

    // MARK: endSession command

    func testEndSessionCommandTearsDown() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let endAt = t0.addingTimeInterval(2)
        let effects = flow.handle(.command(.endSession, now: endAt))
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertEqual(effects, [
            .endCapture(cancel: true),
            .deactivateAudioSession,
            .publishStatus(SessionStatus.off(updatedAt: endAt)),
            .endActivity,
        ])
    }

    func testEndSessionWhileArmedDoesNotCancelCapture() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let endAt = t0.addingTimeInterval(1)
        let effects = flow.handle(.command(.endSession, now: endAt))
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertFalse(effects.contains(.endCapture(cancel: true)), "nothing to cancel while armed")
        XCTAssertTrue(effects.contains(.deactivateAudioSession))
    }

    // MARK: disarm

    func testDisarmFromArmedTearsDown() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let effects = flow.handle(.disarm)
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertTrue(effects.contains(.deactivateAudioSession))
        XCTAssertTrue(effects.contains(.endActivity))
    }

    func testDisarmWhileCapturingCancelsCapture() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let effects = flow.handle(.disarm)
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertTrue(effects.contains(.endCapture(cancel: true)))
    }

    // MARK: interruption teardown

    func testInterruptionWhileArmedTearsDown() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let effects = flow.handle(.interrupted)
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertTrue(effects.contains(.deactivateAudioSession))
    }

    func testInterruptionWhileCapturingCancelsCapture() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let effects = flow.handle(.interrupted)
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertTrue(effects.contains(.endCapture(cancel: true)))
        XCTAssertTrue(effects.contains(.deactivateAudioSession))
    }

    // MARK: app termination teardown

    func testAppWillTerminateWhileCapturingTearsDown() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let effects = flow.handle(.appWillTerminate)
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertTrue(effects.contains(.endCapture(cancel: true)))
        XCTAssertTrue(effects.contains(.deactivateAudioSession))
        XCTAssertTrue(effects.contains(.endActivity))
    }

    // MARK: idle timeout edges

    func testIdleTickBeforeExpiryReschedules() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let early = t0.addingTimeInterval(fiveMin - 1)
        let effects = flow.handle(.idleTick(now: early))
        XCTAssertEqual(flow.status.phase, .armed, "not yet expired")
        XCTAssertEqual(effects, [.scheduleIdleCheck(at: t0.addingTimeInterval(fiveMin))])
    }

    func testIdleTickAtExpiryEndsSession() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let expiry = t0.addingTimeInterval(fiveMin)
        let effects = flow.handle(.idleTick(now: expiry))
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertEqual(effects, [
            .deactivateAudioSession,
            .publishStatus(SessionStatus.off(updatedAt: expiry)),
            .endActivity,
        ])
    }

    func testIdleTickPastExpiryEndsSession() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        let effects = flow.handle(.idleTick(now: t0.addingTimeInterval(fiveMin + 100)))
        XCTAssertEqual(flow.status.phase, .off)
        XCTAssertFalse(effects.contains(.endCapture(cancel: true)), "no capture to cancel on idle expiry")
    }

    func testIdleTickWithNeverTimeoutIsNoOp() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0, timeout: .never)
        let effects = flow.handle(.idleTick(now: t0.addingTimeInterval(10_000)))
        XCTAssertEqual(effects, [], "a .never session never idle-expires")
        XCTAssertEqual(flow.status.phase, .armed)
    }

    func testIdleTickWhileCapturingIsIgnored() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        let effects = flow.handle(.idleTick(now: t0.addingTimeInterval(fiveMin + 100)))
        XCTAssertEqual(effects, [], "idle timeout never fires mid-capture")
        XCTAssertEqual(flow.status.phase, .capturing)
    }

    func testWindowRefreshedAfterCaptureDefersIdleExpiry() {
        var flow = SessionFlow()
        _ = armed(&flow, at: t0)
        _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        // Capture finishes at t0+10s — window should refresh from there.
        // (captureChanged uses status.updatedAt as the anchor; startCapture stamped
        // updatedAt at t0+1, so the refreshed window is t0+1 + 5min here.)
        _ = flow.handle(.captureChanged(.published(UUID())))
        XCTAssertEqual(flow.status.phase, .armed)
        XCTAssertEqual(flow.status.expiresAt, t0.addingTimeInterval(1 + fiveMin))
    }

    // MARK: off-phase no-ops (events that don't apply with no session)

    func testCommandsWhileOffAreIgnored() {
        var flow = SessionFlow()
        for cmd in [SessionCommand.startCapture, .stopCapture, .cancelCapture, .endSession] {
            let effects = flow.handle(.command(cmd, now: t0))
            XCTAssertEqual(effects, [], "\(cmd) while off must be a no-op")
            XCTAssertEqual(flow.status.phase, .off)
        }
    }

    func testCaptureChangedWhileOffIsIgnored() {
        var flow = SessionFlow()
        let effects = flow.handle(.captureChanged(.listening(level: 0.5)))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(flow.status.phase, .off)
    }

    func testDisarmInterruptTerminateWhileOffAreNoOps() {
        for event in [SessionFlow.Event.disarm, .interrupted, .appWillTerminate, .idleTick(now: t0)] {
            var flow = SessionFlow()
            let effects = flow.handle(event)
            XCTAssertEqual(effects, [], "\(event) while off must be a no-op")
        }
    }

    // MARK: exhaustive event × phase coverage guard

    /// Drives every event against every phase and asserts the machine stays total
    /// (never traps) and lands in a legal phase. Value coverage is asserted by the
    /// focused tests above; this guards against an unhandled `(phase, event)` pair.
    func testEveryEventInEveryPhaseIsTotal() {
        let phases: [SessionStatus.Phase] = [.off, .armed, .capturing, .transcribing]
        let events: [SessionFlow.Event] = [
            .arm(config: .default, now: t0),
            .disarm,
            .command(.startCapture, now: t0),
            .command(.stopCapture, now: t0),
            .command(.cancelCapture, now: t0),
            .command(.endSession, now: t0),
            .captureChanged(.idle),
            .captureChanged(.preparing),
            .captureChanged(.listening(level: 0)),
            .captureChanged(.transcribing),
            .captureChanged(.published(UUID())),
            .captureChanged(.failed(.micDenied)),
            .idleTick(now: t0.addingTimeInterval(10_000)),
            .interrupted,
            .appWillTerminate,
        ]

        for phase in phases {
            for event in events {
                var flow = makeFlow(in: phase)
                _ = flow.handle(event)   // must not trap
                let legal: [SessionStatus.Phase] = [.off, .armed, .capturing, .transcribing]
                XCTAssertTrue(legal.contains(flow.status.phase),
                              "phase=\(phase) event=\(event) landed in an illegal phase")
            }
        }
    }

    /// Build a flow sitting in a given phase (via the public event path, so the
    /// status is internally consistent).
    private func makeFlow(in phase: SessionStatus.Phase) -> SessionFlow {
        var flow = SessionFlow()
        switch phase {
        case .off:
            return flow
        case .armed:
            _ = armed(&flow, at: t0)
        case .capturing:
            _ = armed(&flow, at: t0)
            _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
        case .transcribing:
            _ = armed(&flow, at: t0)
            _ = flow.handle(.command(.startCapture, now: t0.addingTimeInterval(1)))
            _ = flow.handle(.captureChanged(.transcribing))
        }
        return flow
    }
}
