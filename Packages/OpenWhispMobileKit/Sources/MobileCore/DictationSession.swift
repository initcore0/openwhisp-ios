import Foundation

// MARK: - Dictation Sessions (ARCHITECTURE §6.8, decisions D11/D12)
//
// A dictation SESSION is a user-armed, auto-expiring window in which the host
// keeps the audio session alive in the background (under the `audio` background
// mode) and the keyboard mic key becomes a live remote control for capture. One
// app-hop arms the session; every dictation after that is instant, no app switch.
//
// The machinery reuses the WP5 handoff patterns wholesale: a pure state machine
// here in MobileCore (SessionFlow), file stores in the App Group with the handoff
// store's atomic claim-rename discipline (SessionCommandMailbox), Darwin pings as
// payload-free wake-ups with a store-read fallback, and the OS-bound drivers in
// CaptureKit / the keyboard shell. Everything in this file is Foundation-only so
// it compiles into both the host app and the memory-tight keyboard extension and
// the whole seam stays `swift test`-able without any OS surface.

// MARK: - DictationSessionConfig

/// User-facing session config (persisted in `SharedStateStore`'s keyboard config).
public struct DictationSessionConfig: Codable, Equatable, Sendable {
    /// How long an idle (armed-but-not-capturing) session survives before it
    /// auto-ends. `.never` means no timeout — the session ends only explicitly
    /// (keyboard, app, Live Activity) or on an unrecoverable interruption.
    public enum IdleTimeout: String, Codable, CaseIterable, Sendable {
        case fiveMinutes, fifteenMinutes, oneHour, never

        /// The timeout as a `TimeInterval`, or `nil` for `.never`.
        public var interval: TimeInterval? {
            switch self {
            case .fiveMinutes: return 5 * 60
            case .fifteenMinutes: return 15 * 60
            case .oneHour: return 60 * 60
            case .never: return nil
            }
        }
    }

    /// Default `.fiveMinutes` (decision D11: a short default owns the mic-privacy story).
    public var idleTimeout: IdleTimeout

    public static let `default` = DictationSessionConfig(idleTimeout: .fiveMinutes)

    public init(idleTimeout: IdleTimeout = .fiveMinutes) {
        self.idleTimeout = idleTimeout
    }
}

// MARK: - SessionStatus

/// The session's phase as the HOST mirrors it into the App Group for the keyboard
/// to read. `updatedAt` is a staleness fence: the host heartbeats while armed
/// (≥ 1 / 15 s), and the keyboard treats an `armed`/`capturing`/`transcribing`
/// status older than `stalenessWindow` as `off` (the host was jetsammed or killed
/// — never show a live mic key for a dead host).
public struct SessionStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case off, armed, capturing, transcribing }

    public let phase: Phase
    public let sessionID: UUID?
    public let armedAt: Date?
    /// `armedAt + idleTimeout`; `nil` for `.never`.
    public let expiresAt: Date?
    public let updatedAt: Date

    /// A status whose `updatedAt` is older than this (relative to the reader's
    /// `now`) is treated as `off`: the host heartbeats far more often (≥ 1/15 s),
    /// so a gap this large means the host process is gone.
    public static let stalenessWindow: TimeInterval = 30

    public init(
        phase: Phase,
        sessionID: UUID?,
        armedAt: Date?,
        expiresAt: Date?,
        updatedAt: Date
    ) {
        self.phase = phase
        self.sessionID = sessionID
        self.armedAt = armedAt
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
    }

    /// The canonical "no session" status.
    public static func off(updatedAt: Date) -> SessionStatus {
        SessionStatus(phase: .off, sessionID: nil, armedAt: nil, expiresAt: nil, updatedAt: updatedAt)
    }

    /// True when this status is older than the staleness window at `now`.
    public func isStale(now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > Self.stalenessWindow
    }

    /// The phase the keyboard should ACT on, folding in the 30 s staleness rule.
    ///
    /// A live phase (`armed`/`capturing`/`transcribing`) whose heartbeat has gone
    /// stale collapses to `.off`: a dead host must never present a live mic key.
    /// `.off` is always itself (a stale `.off` is meaningless but harmless — it
    /// stays `.off`). A future `updatedAt` (cross-process clock skew) is never
    /// stale.
    public func effectivePhase(now: Date) -> Phase {
        guard phase != .off else { return .off }
        return isStale(now: now) ? .off : phase
    }
}

// MARK: - SessionCommand

/// Keyboard → host command channel. A single-slot mailbox file in the App Group
/// (same `O_EXCL` claim-rename atomicity as the handoff store) plus a Darwin ping
/// (`SessionDarwinNames.command`). Commands expire in `sessionCommandExpiry`
/// seconds — a stale `startCapture` must never fire minutes later.
public enum SessionCommand: String, Codable, Sendable {
    case startCapture, stopCapture, cancelCapture, endSession
}

/// A posted command with its post time, so the host can enforce expiry on `take`.
/// This is the on-disk shape of the mailbox slot.
public struct SessionCommandEnvelope: Codable, Equatable, Sendable {
    public let command: SessionCommand
    public let postedAt: Date

    public init(command: SessionCommand, postedAt: Date) {
        self.command = command
        self.postedAt = postedAt
    }

    /// True when `now` is more than `sessionCommandExpiry` after `postedAt`.
    public func isExpired(now: Date) -> Bool {
        now.timeIntervalSince(postedAt) > sessionCommandExpiry
    }
}

/// Single-slot, single-consumer command mailbox.
///
/// Concrete conformer: `AppGroupSessionCommandMailbox` — file-based, `O_EXCL`
/// claim-rename for an atomic take, 5 s command expiry.
/// Test double: `InMemorySessionCommandMailbox`.
public protocol SessionCommandMailbox: Sendable {
    /// Post a command (keyboard side), replacing any currently-pending one.
    func post(_ cmd: SessionCommand, now: Date) throws
    /// Atomically take the pending command iff it is unexpired (host side).
    /// Returns `nil` when the slot was empty, already taken, or expired. On
    /// success — and on expiry — the mailbox is emptied.
    func take(now: Date) throws -> SessionCommand?
}

/// The lifetime of a posted command. A `startCapture` the host reads more than
/// this long after it was posted is dropped, never executed.
public let sessionCommandExpiry: TimeInterval = 5

// MARK: - LivePartial

/// Live partial stream (host → keyboard). A last-writer-wins single file in the
/// App Group plus a Darwin ping (`SessionDarwinNames.partial`, throttled ≤ 8/s).
/// `seq` is monotonic per capture; the keyboard ignores regressions. `isFinal`
/// carries the CLEANED text (the only path a raw partial is replaced wholesale).
public struct LivePartial: Codable, Equatable, Sendable {
    public let captureID: UUID
    public let seq: Int
    public let text: String
    public let isFinal: Bool
    public let updatedAt: Date

    public init(
        captureID: UUID,
        seq: Int,
        text: String,
        isFinal: Bool,
        updatedAt: Date
    ) {
        self.captureID = captureID
        self.seq = seq
        self.text = text
        self.isFinal = isFinal
        self.updatedAt = updatedAt
    }
}

/// Last-writer-wins single-slot partial store (no atomic consume: the keyboard
/// polls, the host overwrites; the newest write wins).
///
/// Concrete conformer: `AppGroupLivePartialStore` (file-based, atomic replace).
/// Test double: `InMemoryLivePartialStore`.
public protocol LivePartialStore: Sendable {
    func write(_ p: LivePartial) throws
    func read() throws -> LivePartial?
    func clear() throws
}

// MARK: - Darwin names

/// The Darwin notification names for the session seam. Payload-free wake-ups; the
/// corresponding store is always the truth (Darwin pings are best-effort).
public enum SessionDarwinNames {
    /// Keyboard → host: a new `SessionCommand` was posted.
    public static let command = "app.openwhisp.session.command"
    /// Host → keyboard: a new `LivePartial` was written.
    public static let partial = "app.openwhisp.session.partial"
    /// Host → keyboard: the `SessionStatus` changed.
    public static let status = "app.openwhisp.session.status"
}
