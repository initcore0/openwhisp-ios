import XCTest
import MobileCore
@testable import CaptureKit

// MARK: - SessionHolder driver tests (WP10b)
//
// Drives the host session driver end-to-end with fakes for every seam — no mic, no
// AVAudioSession, no real timers, no clock — the always-green gate. All the phase
// DECISIONS live in the pure `SessionFlow` (tested exhaustively in MobileCore); here
// we assert the driver PLUMBS them correctly: activates/deactivates audio, delegates
// capture, publishes status, throttles + stamps partials, drains the mailbox, and
// runs the poll/heartbeat only while armed.

// MARK: Fakes

@MainActor
private final class FakeSessionCoordinator: CaptureCoordinating {
    var state: CaptureState = .idle
    var onStateChange: ((CaptureState) -> Void)?
    var onPartial: ((String) -> Void)?

    private(set) var beginCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var lastTrigger: CaptureTrigger?

    func begin(trigger: CaptureTrigger) async { beginCount += 1; lastTrigger = trigger }
    func stop() async { stopCount += 1 }
    func cancel() async { cancelCount += 1 }

    /// Test driver: move to a coarse state and notify (mirrors the real coordinator).
    func emit(_ s: CaptureState) { state = s; onStateChange?(s) }
    func emitPartial(_ t: String) { onPartial?(t) }
}

private final class FakeSessionAudio: SessionAudioControlling, @unchecked Sendable {
    var onInterruption: (() -> Void)?
    private(set) var activateCount = 0
    private(set) var deactivateCount = 0
    var activateError: Error?

    private(set) var suspendCount = 0
    private(set) var resumeCount = 0

    func activateKeepAlive() throws {
        if let activateError { throw activateError }
        activateCount += 1
    }
    func deactivateKeepAlive() { deactivateCount += 1 }
    func suspendKeepAliveTap() { suspendCount += 1 }
    func resumeKeepAliveTap() { resumeCount += 1 }
    func fireInterruption() { onInterruption?() }
}

/// A timer fake that captures the handlers so the test fires ticks by hand, and
/// records the running/idle state of each timer.
private final class FakeSessionTimers: SessionTimerScheduling, @unchecked Sendable {
    var idleDate: Date?
    private var idleHandler: (@Sendable () -> Void)?
    private var heartbeatHandler: (@Sendable () -> Void)?
    private var pollHandler: (@Sendable () -> Void)?

    private(set) var pollRunning = false
    private(set) var heartbeatRunning = false

    func scheduleIdleCheck(at date: Date, onFire: @escaping @Sendable () -> Void) {
        idleDate = date; idleHandler = onFire
    }
    func cancelIdleCheck() { idleDate = nil; idleHandler = nil }
    func startHeartbeat(interval: TimeInterval, onTick: @escaping @Sendable () -> Void) {
        heartbeatHandler = onTick; heartbeatRunning = true
    }
    func stopHeartbeat() { heartbeatHandler = nil; heartbeatRunning = false }
    func startMailboxPoll(interval: TimeInterval, onTick: @escaping @Sendable () -> Void) {
        pollHandler = onTick; pollRunning = true
    }
    func stopMailboxPoll() { pollHandler = nil; pollRunning = false }

    func fireIdle() { idleHandler?() }
    func fireHeartbeat() { heartbeatHandler?() }
    func firePoll() { pollHandler?() }
}

private final class FakeActivity: SessionActivityDriving, @unchecked Sendable {
    private(set) var updates: [SessionStatus] = []
    private(set) var endCount = 0
    func update(_ status: SessionStatus) { updates.append(status) }
    func end() { endCount += 1 }
}

// MARK: Tests

@MainActor
final class SessionHolderTests: XCTestCase {

    private var coord: FakeSessionCoordinator!
    private var audio: FakeSessionAudio!
    private var timers: FakeSessionTimers!
    private var mailbox: InMemorySessionCommandMailbox!
    private var partials: InMemoryLivePartialStore!
    private var status: InMemorySessionStatusStore!
    private var activity: FakeActivity!
    private var clock: Date!
    private var mono: TimeInterval!
    private var statusPings = 0
    private var partialPings = 0

    private func makeHolder(cleanedFinal: @escaping (UUID) -> String? = { _ in nil }) -> SessionHolder {
        coord = FakeSessionCoordinator()
        audio = FakeSessionAudio()
        timers = FakeSessionTimers()
        mailbox = InMemorySessionCommandMailbox()
        partials = InMemoryLivePartialStore()
        status = InMemorySessionStatusStore()
        activity = FakeActivity()
        clock = Date(timeIntervalSince1970: 5_000_000)
        mono = 1000
        return SessionHolder(
            coordinator: coord, audio: audio, timers: timers,
            commandMailbox: mailbox, partialStore: partials, statusStore: status,
            activity: activity,
            cleanedFinal: cleanedFinal,
            notifyStatus: { self.statusPings += 1 },
            notifyPartial: { self.partialPings += 1 },
            now: { self.clock },
            monotonic: { self.mono }
        )
    }

    // MARK: arm / disarm

    func testArmActivatesAudioPublishesArmedAndStartsTimers() throws {
        let holder = makeHolder()
        holder.arm(config: DictationSessionConfig(idleTimeout: .fiveMinutes))

        XCTAssertEqual(audio.activateCount, 1)
        XCTAssertEqual(try status.read()?.phase, .armed)
        XCTAssertTrue(activity.updates.contains { $0.phase == .armed })
        XCTAssertTrue(timers.pollRunning)
        XCTAssertTrue(timers.heartbeatRunning)
        XCTAssertNotNil(timers.idleDate)         // fiveMinutes → an idle check scheduled
        XCTAssertTrue(holder.isArmed)
        XCTAssertGreaterThan(statusPings, 0)
    }

    func testNeverTimeoutSchedulesNoIdleCheck() {
        let holder = makeHolder()
        holder.arm(config: DictationSessionConfig(idleTimeout: .never))
        XCTAssertNil(timers.idleDate)
        XCTAssertTrue(holder.isArmed)
    }

    func testArmFailureAtAudioLayerTearsDown() throws {
        let holder = makeHolder()
        audio.activateError = FakeError(message: "no session")
        holder.arm(config: .default)
        // Activation failed → interrupted teardown: deactivate, status off, activity ended.
        XCTAssertEqual(audio.deactivateCount, 1)
        XCTAssertEqual(try status.read()?.phase, .off)
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertFalse(holder.isArmed)
        XCTAssertFalse(timers.pollRunning)
    }

    func testEndSessionDeactivatesAndEndsActivity() throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        holder.endSession()
        XCTAssertEqual(audio.deactivateCount, 1)
        XCTAssertEqual(try status.read()?.phase, .off)
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertFalse(timers.pollRunning)
        XCTAssertFalse(timers.heartbeatRunning)
    }

    /// The executor delegates capture through `Task { await coordinator… }`; on the
    /// main actor those Tasks run when the test yields. A couple of hops drains them.
    private func flush() async {
        for _ in 0..<4 { await Task.yield() }
    }

    // MARK: command intake → capture delegation

    func testStartCaptureCommandBeginsCaptureAndPublishesCapturing() async throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        try mailbox.post(.startCapture, now: clock)
        holder.onCommandPing()
        await flush()

        XCTAssertEqual(coord.beginCount, 1)
        XCTAssertEqual(coord.lastTrigger, .keyboardHandoff)
        XCTAssertEqual(try status.read()?.phase, .capturing)
    }

    func testStopCaptureCommandStopsCoordinator() async throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        try mailbox.post(.startCapture, now: clock)
        holder.onCommandPing()
        coord.emit(.listening(level: 0.4))     // capture is genuinely live

        try mailbox.post(.stopCapture, now: clock)
        holder.onCommandPing()
        await flush()
        XCTAssertEqual(coord.stopCount, 1)
    }

    func testMailboxPollDrainsCommands() async throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        try mailbox.post(.startCapture, now: clock)
        timers.firePoll()                       // the 250 ms poll, not the Darwin ping
        await flush()
        XCTAssertEqual(coord.beginCount, 1)
    }

    // MARK: partials — throttle + final

    func testInterimPartialsAreThrottledAndSequenced() throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        try mailbox.post(.startCapture, now: clock)
        holder.onCommandPing()                  // → capturing

        coord.emitPartial("he")                 // first: written, seq 1
        XCTAssertEqual(try partials.read()?.seq, 1)
        XCTAssertEqual(try partials.read()?.text, "he")

        mono += 0.05                            // < 125 ms → dropped
        coord.emitPartial("hell")
        XCTAssertEqual(try partials.read()?.seq, 1)

        mono += 0.1                             // now ≥ 125 ms total → written, seq 2
        coord.emitPartial("hello")
        XCTAssertEqual(try partials.read()?.seq, 2)
        XCTAssertEqual(try partials.read()?.text, "hello")
    }

    func testPartialsIgnoredWhenNotCapturing() throws {
        let holder = makeHolder()
        holder.arm(config: .default)            // armed, NOT capturing
        coord.emitPartial("stray")
        XCTAssertNil(try partials.read())
    }

    func testCleanedFinalIsStampedOnPublish() throws {
        let publishedID = UUID()
        let holder = makeHolder(cleanedFinal: { $0 == publishedID ? "Hello, world." : nil })
        holder.arm(config: .default)
        try mailbox.post(.startCapture, now: clock)
        holder.onCommandPing()
        coord.emitPartial("hello world")

        coord.emit(.published(publishedID))
        let final = try XCTUnwrap(try partials.read())
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.text, "Hello, world.")
        // Publishing returns the session to armed.
        XCTAssertEqual(try status.read()?.phase, .armed)
    }

    func testKeepAliveTapIsSuspendedForCaptureAndResumedAfter() throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        try mailbox.post(.startCapture, now: clock)
        holder.onCommandPing()                  // → beginCapture: tap suspended
        XCTAssertEqual(audio.suspendCount, 1)
        XCTAssertEqual(audio.resumeCount, 0)

        coord.emit(.listening(level: 0.3))
        coord.emit(.published(UUID()))          // capture ends, session stays armed
        XCTAssertEqual(audio.resumeCount, 1)    // tap reinstalled for the idle window
    }

    // MARK: idle timeout + heartbeat + interruption

    func testIdleTickAtExpiryEndsSession() throws {
        let holder = makeHolder()
        holder.arm(config: DictationSessionConfig(idleTimeout: .fiveMinutes))
        // Advance the clock past expiry, then fire the idle timer.
        clock = clock.addingTimeInterval(600)
        timers.fireIdle()
        XCTAssertEqual(try status.read()?.phase, .off)
        XCTAssertEqual(activity.endCount, 1)
        XCTAssertFalse(holder.isArmed)
    }

    func testHeartbeatRestampsStatusWithoutChangingPhase() throws {
        let holder = makeHolder()
        holder.arm(config: DictationSessionConfig(idleTimeout: .never))
        let armedAt = try XCTUnwrap(try status.read()?.updatedAt)
        clock = clock.addingTimeInterval(10)
        timers.fireHeartbeat()
        let beat = try XCTUnwrap(try status.read())
        XCTAssertEqual(beat.phase, .armed)                    // phase unchanged
        XCTAssertEqual(beat.updatedAt, armedAt.addingTimeInterval(10)) // fresh heartbeat
    }

    func testInterruptionEndsSession() throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        audio.fireInterruption()
        XCTAssertEqual(try status.read()?.phase, .off)
        XCTAssertEqual(audio.deactivateCount, 1)
        XCTAssertFalse(holder.isArmed)
    }

    func testAppWillTerminateTearsDown() throws {
        let holder = makeHolder()
        holder.arm(config: .default)
        holder.appWillTerminate()
        XCTAssertEqual(try status.read()?.phase, .off)
        XCTAssertFalse(holder.isArmed)
    }
}
