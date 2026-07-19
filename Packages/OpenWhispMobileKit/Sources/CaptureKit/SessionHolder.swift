import Foundation
import MobileCore

// MARK: - SessionHolder — the host session driver (ARCHITECTURE §6.8 driver notes)
//
// The host-side driver of a Dictation Session (WP10b). It owns the armed window:
// arming activates the shared audio session and keeps a minimal keep-alive engine
// tap live so iOS keeps the process running under the `audio` background mode; the
// keyboard's mic key then starts/stops capture INSTANTLY for the rest of the window
// (one app-hop amortized across the whole session — D11).
//
// Just like `CaptureCoordinator` is the literal executor of `CaptureFlow`, this is
// the literal executor of the pure `SessionFlow` state machine (MobileCore, WP10a):
// it feeds events in (arm/disarm, mailbox commands, capture-state feedback, idle
// ticks, interruption/termination) and runs the `Effect`s the machine emits — one at
// a time. All the decision logic lives in `SessionFlow`; this file is the OS-bound
// plumbing SessionFlow deliberately cannot express (timers, Darwin notifications,
// the file stores, and delegating capture to a `CaptureCoordinating`).
//
// SEAMS for testability (so the driver's plumbing is `swift test`-covered without a
// real coordinator, mic, or clock):
//   - `CaptureCoordinating` (MobileCore): the capture delegate. The real coordinator
//     drives `AVAudioEngine`; tests pass a fake.
//   - `SessionAudioControlling`: the keep-alive audio-session lever. The real
//     conformer activates `.playAndRecord`/`.measurement` and holds a silent tap;
//     tests pass a fake and assert activate/deactivate.
//   - `SessionTimerScheduling`: the idle-check + heartbeat timers. The real conformer
//     uses `DispatchSourceTimer`; tests fire ticks by hand.
//   - `SessionCommandMailbox` / `LivePartialStore` / `SessionStatusStore`: the App
//     Group stores; tests pass the in-memory doubles.
//   - `SessionActivityDriving`: the Live Activity seam the HOST APP implements
//     (CaptureKit can't import ActivityKit); a closure-backed default no-ops.
//
// The keyboard NEVER runs this — it only posts commands and reads the partial/status
// stores. This driver is the sole writer of the status + partial slots.

// MARK: - Driver seams

/// The keep-alive audio-session lever (distinct from `AudioSessionControlling`, which
/// is per-CAPTURE): arming a session activates `.playAndRecord`/`.measurement` and
/// holds a minimal silent engine tap so the `audio` background mode keeps the process
/// alive across the whole armed window; disarming releases it. Interruptions the tap
/// can't recover surface via `onInterruption` → the driver ends the session.
public protocol SessionAudioControlling: AnyObject {
    /// Activate the shared session and start the silent keep-alive tap. Throws if
    /// the session is unavailable (arming then fails cleanly).
    func activateKeepAlive() throws
    /// Release the keep-alive tap and deactivate the shared session.
    func deactivateKeepAlive()
    /// Remove the keep-alive tap so the capture engine can install its OWN tap on the
    /// shared input node (AVAudioEngine allows only one tap per bus). Called by the
    /// driver right before a capture begins; the shared audio session stays active.
    func suspendKeepAliveTap()
    /// Reinstall the keep-alive tap after a capture ends, so the armed-but-idle
    /// session keeps a live graph for the `audio` background mode. Called by the
    /// driver when capture returns to armed.
    func resumeKeepAliveTap()
    /// Fired when the OS interrupts the session in a way the keep-alive can't recover
    /// (a phone call that ends the session, route loss with no input). The driver
    /// maps it to `SessionFlow.Event.interrupted`.
    var onInterruption: (() -> Void)? { get set }
}

/// The two timers the driver needs, abstracted so tests fire them synchronously.
/// `scheduleIdleCheck` (re)arms a one-shot at the session's `expiresAt`; `heartbeat`
/// is a repeating timer that re-stamps the status while armed (≥ 1/15 s so the
/// keyboard's 30 s staleness fence never trips on a live host).
public protocol SessionTimerScheduling: AnyObject {
    /// (Re)schedule the one-shot idle check to fire at `date`; replaces any pending
    /// one. `onFire` runs on the main actor.
    func scheduleIdleCheck(at date: Date, onFire: @escaping @Sendable () -> Void)
    /// Cancel a pending idle check (teardown).
    func cancelIdleCheck()
    /// Start the repeating heartbeat at `interval`, replacing any running one.
    func startHeartbeat(interval: TimeInterval, onTick: @escaping @Sendable () -> Void)
    /// Stop the heartbeat (teardown).
    func stopHeartbeat()
    /// Start the 250 ms command-mailbox poll (Darwin is best-effort; the poll is the
    /// floor). Replaces any running poll.
    func startMailboxPoll(interval: TimeInterval, onTick: @escaping @Sendable () -> Void)
    /// Stop the mailbox poll (teardown).
    func stopMailboxPoll()
}

/// The Live Activity seam. CaptureKit can't import ActivityKit (it's an app-process
/// UI framework), so the HOST APP conforms this to `LiveActivityController`-style
/// calls; a default closure-backed implementation lets tests observe the intent.
public protocol SessionActivityDriving: AnyObject {
    /// The session status changed — update (or start) the armed/capturing activity.
    func update(_ status: SessionStatus)
    /// The session ended — end the activity.
    func end()
}

/// The heartbeat cadence: re-stamp the status at least this often while armed so the
/// keyboard's `SessionStatus.stalenessWindow` (30 s) never trips on a live host.
/// 10 s gives 3× headroom.
public let sessionHeartbeatInterval: TimeInterval = 10

/// The command-mailbox poll cadence while armed (R10b: Darwin pings are best-effort,
/// the 250 ms poll is the reliability floor).
public let sessionMailboxPollInterval: TimeInterval = 0.25

// MARK: - SessionHolder

@MainActor
public final class SessionHolder {

    // MARK: Collaborators

    private var flow: SessionFlow
    private let coordinator: CaptureCoordinating
    private let audio: SessionAudioControlling
    private let timers: SessionTimerScheduling
    private let commandMailbox: SessionCommandMailbox
    private let partialStore: LivePartialStore
    private let statusStore: SessionStatusStore
    private let activity: SessionActivityDriving?
    /// Resolves the CLEANED published text for a `.published(id)` capture, so the
    /// driver can stamp the final partial with clean text. The host passes a closure
    /// that peeks the handoff store (the same peek the composer/sheet do); `nil`
    /// means "no cleaned final available" and the interim stream's last text stands.
    private let cleanedFinal: (UUID) -> String?
    private let notifyStatus: () -> Void
    private let notifyPartial: () -> Void
    private let now: () -> Date
    /// Monotonic clock for the partial throttle (wall-clock is fine for the status
    /// heartbeat/expiry, but the throttle must be immune to clock adjustments).
    private let monotonic: () -> TimeInterval

    private var publisher = LivePartialPublisher()

    /// Whether the session is currently live (any non-`.off` effective phase). Drives
    /// whether the poll/heartbeat run.
    public var isArmed: Bool { flow.status.phase != .off }

    public init(
        coordinator: CaptureCoordinating,
        audio: SessionAudioControlling,
        timers: SessionTimerScheduling,
        commandMailbox: SessionCommandMailbox,
        partialStore: LivePartialStore,
        statusStore: SessionStatusStore,
        activity: SessionActivityDriving? = nil,
        cleanedFinal: @escaping (UUID) -> String? = { _ in nil },
        notifyStatus: @escaping () -> Void = {},
        notifyPartial: @escaping () -> Void = {},
        now: @escaping () -> Date = Date.init,
        monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.flow = SessionFlow()
        self.coordinator = coordinator
        self.audio = audio
        self.timers = timers
        self.commandMailbox = commandMailbox
        self.partialStore = partialStore
        self.statusStore = statusStore
        self.activity = activity
        self.cleanedFinal = cleanedFinal
        self.notifyStatus = notifyStatus
        self.notifyPartial = notifyPartial
        self.now = now
        self.monotonic = monotonic

        wire()
    }

    // MARK: - Public control

    /// Arm a session (the one foreground hop). Activates audio + keep-alive tap,
    /// publishes `armed`, and starts the poll/heartbeat. Idempotent-ish: re-arming a
    /// live session just refreshes its idle window (SessionFlow decides).
    public func arm(config: DictationSessionConfig) {
        dispatch(.arm(config: config, now: now()))
    }

    /// End the session explicitly (the app / Live Activity End Session button).
    public func endSession() {
        dispatch(.disarm)
    }

    /// The app is terminating — tear the session down cleanly.
    public func appWillTerminate() {
        dispatch(.appWillTerminate)
    }

    /// A Darwin command ping arrived — drain the mailbox now (the 250 ms poll is the
    /// floor; this makes the common case instant).
    public func onCommandPing() {
        drainMailbox()
    }

    // MARK: - Wiring

    private func wire() {
        // These callbacks all fire on the main actor (the coordinator is `@MainActor`
        // and the audio conformer posts on the main queue), so they run the driver's
        // `@MainActor` methods DIRECTLY — no `Task` hop, which would reorder a partial
        // after a state change and make the driver's own ordering nondeterministic.
        MainActor.assumeIsolated {
            // Capture-state feedback → SessionFlow. The coordinator drives a single
            // capture inside the armed window; its coarse state maps to the phase.
            coordinator.onStateChange = { [weak self] state in
                MainActor.assumeIsolated { self?.handleCaptureChanged(state) }
            }
            // Rolling interim partials → the live-partial stream (throttled, D12/R10b).
            coordinator.onPartial = { [weak self] text in
                MainActor.assumeIsolated { self?.publishInterim(text) }
            }
        }
        // An unrecoverable audio interruption ends the session.
        audio.onInterruption = { [weak self] in
            MainActor.assumeIsolated { self?.dispatch(.interrupted) }
        }
    }

    /// Poll the mailbox for a command and feed it in. Called by the 250 ms poll and
    /// by the Darwin ping.
    private func drainMailbox() {
        guard let cmd = try? commandMailbox.take(now: now()) else { return }
        dispatch(.command(cmd, now: now()))
    }

    private func handleCaptureChanged(_ state: CaptureState) {
        // When a capture publishes, stamp the CLEANED final into the partial stream
        // BEFORE feeding the state back (so the keyboard's last partial is the clean
        // text, then the phase returns to armed). The cleaned text is resolved via the
        // injected `cleanedFinal` seam (the host peeks the handoff store — the same
        // peek the composer/sheet do). If it yields nil the interim stream's last text
        // already stands; we just return to armed.
        if case .published(let id) = state, let cleaned = cleanedFinal(id) {
            if let p = publisher.final(cleaned, at: now()) {
                try? partialStore.write(p)
                notifyPartial()
            }
        }
        // When a capture settles back to a terminal coordinator state — but the
        // SESSION stays armed — reinstall the keep-alive tap so the idle window keeps
        // a live graph. (Teardown paths deactivate audio entirely, so this only
        // matters when the session survives the capture.)
        switch state {
        case .idle, .published, .failed:
            if flow.status.phase == .capturing || flow.status.phase == .transcribing {
                audio.resumeKeepAliveTap()
            }
        case .preparing, .listening, .transcribing:
            break
        }
        dispatch(.captureChanged(state))
    }

    private func publishInterim(_ text: String) {
        guard flow.status.phase == .capturing else { return }
        if let p = publisher.offer(text, now: monotonic(), at: now()) {
            try? partialStore.write(p)
            notifyPartial()
        }
    }

    // MARK: - The literal effect executor

    /// Re-entrant events an effect fed back in (e.g. `.activateAudioSession` failing
    /// and enqueuing `.interrupted`). Draining them AFTER the current event's whole
    /// batch finishes preserves SessionFlow's own effect ordering — a follow-up event
    /// must not run mid-batch, or a trailing `.publishStatus(armed)` from the arm
    /// batch would clobber the `.off` a nested teardown just published. Mirrors
    /// `CaptureCoordinator`'s dispatch queue.
    private var pendingEvents: [SessionFlow.Event] = []
    private var draining = false

    private func dispatch(_ event: SessionFlow.Event) {
        pendingEvents.append(event)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !pendingEvents.isEmpty {
            let next = pendingEvents.removeFirst()
            for effect in flow.handle(next) {
                execute(effect)
            }
        }
        // After the whole queue drains, keep the poll/heartbeat in step with armed-ness.
        syncBackgroundTimers()
    }

    private func execute(_ effect: SessionFlow.Effect) {
        switch effect {
        case .activateAudioSession:
            do {
                try audio.activateKeepAlive()
            } catch {
                // Arming failed at the audio layer — tear the session back down so we
                // never publish an `armed` status for a dead session.
                dispatch(.interrupted)
            }

        case .deactivateAudioSession:
            audio.deactivateKeepAlive()

        case .beginCapture(let trigger):
            // A fresh capture: hand the shared input node to the capture engine (drop
            // our keep-alive tap so the two don't fight over bus 0), reset the partial
            // sequencer, and start the coordinator.
            audio.suspendKeepAliveTap()
            _ = publisher.begin()
            Task { await coordinator.begin(trigger: trigger) }

        case .endCapture(let cancel):
            Task {
                if cancel { await coordinator.cancel() } else { await coordinator.stop() }
            }

        case .publishStatus(let status):
            try? statusStore.write(status)
            notifyStatus()

        case .updateActivity(let status):
            activity?.update(status)

        case .endActivity:
            // The session is over: end the activity, clear the partial slot, and drop
            // the status to `.off` (the last publishStatus already wrote `.off`; a
            // clear would race the keyboard's read, so we leave the `.off` in place).
            activity?.end()
            publisher.end()
            try? partialStore.clear()

        case .scheduleIdleCheck(let date):
            // The real timer fires on the main queue; assumeIsolated keeps the tick
            // synchronous so the driver's ordering is deterministic (and testable).
            timers.scheduleIdleCheck(at: date) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.dispatch(.idleTick(now: self.now()))
                }
            }
        }
    }

    /// Start/stop the mailbox poll + heartbeat to match armed-ness. The heartbeat
    /// re-stamps the CURRENT status (a pure `updatedAt` bump) so the keyboard's
    /// staleness fence never trips on a live-but-idle host.
    private func syncBackgroundTimers() {
        if isArmed {
            timers.startMailboxPoll(interval: sessionMailboxPollInterval) { [weak self] in
                MainActor.assumeIsolated { self?.drainMailbox() }
            }
            timers.startHeartbeat(interval: sessionHeartbeatInterval) { [weak self] in
                MainActor.assumeIsolated { self?.heartbeat() }
            }
        } else {
            timers.stopMailboxPoll()
            timers.stopHeartbeat()
            timers.cancelIdleCheck()
        }
    }

    /// Re-stamp the current status with a fresh `updatedAt` (the heartbeat). Does NOT
    /// go through SessionFlow — it's a pure liveness bump that must not move the phase
    /// or the idle window. Skipped when off.
    private func heartbeat() {
        guard isArmed else { return }
        let s = flow.status
        let beat = SessionStatus(
            phase: s.phase,
            sessionID: s.sessionID,
            armedAt: s.armedAt,
            expiresAt: s.expiresAt,
            updatedAt: now()
        )
        try? statusStore.write(beat)
        notifyStatus()
    }
}
