import Foundation

// MARK: - Session state machine (ARCHITECTURE §6.8)
//
// The pure session state machine — CaptureFlow's sibling. The HOST drives it:
// arm/disarm, command intake from the keyboard mailbox, capture delegation to
// CaptureFlow, idle-timeout bookkeeping, interruption teardown. Nothing here
// touches the OS; the `SessionHolder` driver (CaptureKit, WP10b) interprets the
// `Effect`s. Total by construction — every `(phase, event)` pair is handled
// explicitly — and tested exhaustively.
//
// Relationship to CaptureFlow: SessionFlow owns the ARMED WINDOW; CaptureFlow
// owns a single capture inside it. The driver runs both — it feeds CaptureFlow's
// coarse `CaptureState` back here via `.captureChanged`, and SessionFlow maps
// that to the cross-process `SessionStatus.Phase` the keyboard reads. SessionFlow
// never itself decides to publish transcripts — that stays CaptureFlow's job.

public struct SessionFlow: Equatable, Sendable {

    public enum Event: Sendable, Equatable {
        /// The user armed a session (one foreground hop). Carries the config so
        /// the idle timeout is fixed at arm time.
        case arm(config: DictationSessionConfig, now: Date)
        /// The session was ended explicitly from the app or Live Activity.
        case disarm
        /// A command arrived from the keyboard mailbox (already un-stale-checked
        /// by the mailbox's `take`; `now` lets us re-stamp status).
        case command(SessionCommand, now: Date)
        /// CaptureFlow's coarse state changed (the driver feeds it back here).
        case captureChanged(CaptureState)
        /// The idle-timeout timer fired; `now` decides whether we actually expired.
        case idleTick(now: Date)
        /// An audio interruption the driver could not recover — tear the session down.
        case interrupted
        /// The app is terminating — tear the session down cleanly.
        case appWillTerminate
    }

    public enum Effect: Sendable, Equatable {
        case activateAudioSession
        case deactivateAudioSession
        case beginCapture(CaptureTrigger)
        case endCapture(cancel: Bool)
        case publishStatus(SessionStatus)
        case updateActivity(SessionStatus)
        case endActivity
        /// Ask the driver to schedule an idle check at `at` (the session's
        /// `expiresAt`). Never emitted for `.never` timeouts.
        case scheduleIdleCheck(at: Date)
    }

    public private(set) var status: SessionStatus

    /// The config captured at arm time (idle timeout is fixed for the window).
    private var config: DictationSessionConfig?

    /// An armed session is created with a `SessionStatus.off` at epoch, so a
    /// freshly-constructed flow reads as "no session" until the first `.arm`.
    public init() {
        self.status = SessionStatus.off(updatedAt: Date(timeIntervalSince1970: 0))
        self.config = nil
    }

    /// Test/preview seam: start from a given status (e.g. an already-armed flow).
    public init(status: SessionStatus, config: DictationSessionConfig?) {
        self.status = status
        self.config = config
    }

    // MARK: handle

    /// Advance the machine. Returns the effects the driver must execute, in order.
    ///
    /// Design rules:
    /// - Arming is only meaningful from `.off`; re-arming a live session just
    ///   re-stamps the window (fresh `armedAt`/`expiresAt`) without re-activating
    ///   audio (it is already live).
    /// - `disarm` / `interrupted` / `appWillTerminate` tear down from ANY live
    ///   phase and are no-ops from `.off`. Teardown is always explicit effects.
    /// - Capture commands only apply while a session is live; a `startCapture`
    ///   after the host is gone can't reach here (the mailbox drops stale ones,
    ///   and an `.off` flow ignores commands).
    /// - `idleTick` expires the session ONLY while `.armed` (never mid-capture)
    ///   and ONLY once `now >= expiresAt`; earlier ticks reschedule.
    public mutating func handle(_ event: Event) -> [Effect] {
        switch (status.phase, event) {

        // MARK: arm
        case (.off, .arm(let config, let now)):
            self.config = config
            let expiresAt = config.idleTimeout.interval.map { now.addingTimeInterval($0) }
            status = SessionStatus(
                phase: .armed,
                sessionID: UUID(),
                armedAt: now,
                expiresAt: expiresAt,
                updatedAt: now
            )
            var effects: [Effect] = [
                .activateAudioSession,
                .publishStatus(status),
                .updateActivity(status),
            ]
            if let expiresAt { effects.append(.scheduleIdleCheck(at: expiresAt)) }
            return effects

        case (_, .arm(let config, let now)):
            // Re-arm of a live session: refresh the idle window (a re-hop is the
            // user re-asserting the session), but audio is already live.
            self.config = config
            let expiresAt = config.idleTimeout.interval.map { now.addingTimeInterval($0) }
            status = SessionStatus(
                phase: status.phase,
                sessionID: status.sessionID,
                armedAt: now,
                expiresAt: expiresAt,
                updatedAt: now
            )
            var effects: [Effect] = [.publishStatus(status), .updateActivity(status)]
            if status.phase == .armed, let expiresAt {
                effects.append(.scheduleIdleCheck(at: expiresAt))
            }
            return effects

        // MARK: disarm / termination / interruption — teardown from any live phase
        case (.off, .disarm), (.off, .interrupted), (.off, .appWillTerminate):
            // Nothing armed; nothing to tear down.
            return []

        case (_, .disarm), (_, .appWillTerminate):
            let capturing = status.phase == .capturing || status.phase == .transcribing
            return teardown(now: status.updatedAt, cancelCapture: capturing)

        case (_, .interrupted):
            let capturing = status.phase == .capturing || status.phase == .transcribing
            return teardown(now: status.updatedAt, cancelCapture: capturing)

        // MARK: command intake (only while a session is live)
        case (.off, .command):
            // No session: a stray command (the host was just torn down) is ignored.
            return []

        case (_, .command(let cmd, let now)):
            return handleCommand(cmd, now: now)

        // MARK: capture state feedback
        case (.off, .captureChanged):
            // Capture can't be running without a session; ignore.
            return []

        case (_, .captureChanged(let captureState)):
            return handleCaptureChanged(captureState)

        // MARK: idle timeout
        case (.armed, .idleTick(let now)):
            guard let expiresAt = status.expiresAt else {
                // `.never` timeout: an idleTick is spurious — do nothing.
                return []
            }
            if now >= expiresAt {
                // The window elapsed with no capture: end the session.
                return teardown(now: now, cancelCapture: false)
            }
            // Not yet — reschedule for the (possibly refreshed) expiry.
            return [.scheduleIdleCheck(at: expiresAt)]

        case (.off, .idleTick), (.capturing, .idleTick), (.transcribing, .idleTick):
            // Idle timeout never fires mid-capture (capturing resets the window on
            // return to armed), and there is nothing to expire when off.
            return []
        }
    }

    // MARK: - command handling

    private mutating func handleCommand(_ cmd: SessionCommand, now: Date) -> [Effect] {
        switch cmd {
        case .startCapture:
            guard status.phase == .armed else {
                // A second startCapture while already capturing is redundant.
                return []
            }
            status = restamp(phase: .capturing, now: now, refreshWindow: false)
            return [.beginCapture(.keyboardHandoff), .publishStatus(status), .updateActivity(status)]

        case .stopCapture:
            guard status.phase == .capturing else { return [] }
            // Normal stop: let the in-flight decode finish (cancel: false); the
            // phase advances to .transcribing when the driver reports it back via
            // `.captureChanged`.
            return [.endCapture(cancel: false)]

        case .cancelCapture:
            guard status.phase == .capturing || status.phase == .transcribing else { return [] }
            // Discard the capture and return to armed, refreshing the idle window
            // (the user is still actively in the session).
            status = restamp(phase: .armed, now: now, refreshWindow: true)
            var effects: [Effect] = [.endCapture(cancel: true), .publishStatus(status), .updateActivity(status)]
            if let expiresAt = status.expiresAt { effects.append(.scheduleIdleCheck(at: expiresAt)) }
            return effects

        case .endSession:
            let capturing = status.phase == .capturing || status.phase == .transcribing
            return teardown(now: now, cancelCapture: capturing)
        }
    }

    // MARK: - capture-state feedback

    private mutating func handleCaptureChanged(_ captureState: CaptureState) -> [Effect] {
        switch captureState {
        case .idle, .published:
            // A capture finished (or was cancelled): return to armed and refresh
            // the idle window from the capture's end. Only meaningful if we were
            // mid-capture — a redundant idle report while already armed is a no-op.
            guard status.phase == .capturing || status.phase == .transcribing else { return [] }
            status = restamp(phase: .armed, now: status.updatedAt, refreshWindow: true)
            var effects: [Effect] = [.publishStatus(status), .updateActivity(status)]
            if let expiresAt = status.expiresAt { effects.append(.scheduleIdleCheck(at: expiresAt)) }
            return effects

        case .preparing, .listening:
            // Capture is live. Reflect `.capturing` if we somehow lagged (the
            // command already set it); no window refresh while capturing.
            guard status.phase != .capturing else { return [] }
            status = restamp(phase: .capturing, now: status.updatedAt, refreshWindow: false)
            return [.publishStatus(status), .updateActivity(status)]

        case .transcribing:
            guard status.phase != .transcribing else { return [] }
            status = restamp(phase: .transcribing, now: status.updatedAt, refreshWindow: false)
            return [.publishStatus(status), .updateActivity(status)]

        case .failed:
            // A capture failure inside a session doesn't kill the session — it
            // drops back to armed so the user can retry. Window refreshed.
            guard status.phase == .capturing || status.phase == .transcribing else { return [] }
            status = restamp(phase: .armed, now: status.updatedAt, refreshWindow: true)
            var effects: [Effect] = [.publishStatus(status), .updateActivity(status)]
            if let expiresAt = status.expiresAt { effects.append(.scheduleIdleCheck(at: expiresAt)) }
            return effects
        }
    }

    // MARK: - helpers

    /// Tear the whole session down: end any live capture, drop the audio session,
    /// publish `.off`, end the Live Activity. `config` is cleared. Always explicit
    /// effects (no implicit teardown), mirroring CaptureFlow's doctrine.
    private mutating func teardown(now: Date, cancelCapture: Bool) -> [Effect] {
        var effects: [Effect] = []
        if cancelCapture {
            effects.append(.endCapture(cancel: true))
        }
        effects.append(.deactivateAudioSession)
        config = nil
        status = SessionStatus.off(updatedAt: now)
        effects.append(.publishStatus(status))
        effects.append(.endActivity)
        return effects
    }

    /// Produce a new status for `phase`, keeping the session identity. When
    /// `refreshWindow` is true the idle window is recomputed from `now` (a fresh
    /// `armedAt`); otherwise the original `armedAt`/`expiresAt` are preserved and
    /// only `updatedAt` advances (a heartbeat).
    private func restamp(phase: SessionStatus.Phase, now: Date, refreshWindow: Bool) -> SessionStatus {
        let armedAt = refreshWindow ? now : status.armedAt
        let expiresAt: Date?
        if refreshWindow {
            expiresAt = config?.idleTimeout.interval.map { now.addingTimeInterval($0) }
        } else {
            expiresAt = status.expiresAt
        }
        return SessionStatus(
            phase: phase,
            sessionID: status.sessionID,
            armedAt: armedAt,
            expiresAt: expiresAt,
            updatedAt: now
        )
    }
}
