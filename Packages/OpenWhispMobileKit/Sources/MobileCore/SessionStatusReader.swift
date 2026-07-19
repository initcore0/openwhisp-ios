import Foundation

// MARK: - Session status seam (ARCHITECTURE §6.8) — WP10c reader side
//
// The keyboard needs to READ the host's `SessionStatus` to decide what the mic key
// means (`MicKeyResolver.resolveSession`). WP10a shipped `SessionStatus` (with its
// 30 s staleness fence) and the command/partial file stores, but deliberately left
// the STATUS transport to be wired later — the WP10a note on `SessionEnvironment`
// says "the `SessionStatus` itself rides the existing shared state file surface
// (WP10b wires it)".
//
// WP10c must resolve the mic key today, without being blocked by WP10b, so it
// defines this small reader seam now:
//
//   • `SessionStatusReading` — the read-only protocol the keyboard depends on.
//   • `AppGroupSessionStatusReader` — the file-backed conformer, reading
//     `session/status.json` under the App Group container, in the SAME `session/`
//     directory as `AppGroupSessionCommandMailbox` / `AppGroupLivePartialStore`.
//   • `InMemorySessionStatusReader` — the test/preview double.
//
// This is intentionally ADDITIVE and reader-only. The host (WP10b) writes
// `status.json` (a JSON-encoded `SessionStatus`) with the same atomic-replace
// discipline as the other session files; the two sides agree on nothing but the
// path (`session/status.json`) and the format (a `Codable` `SessionStatus`). If the
// host has not written the file yet, the reader returns a fresh `.off` status, so
// `effectivePhase` is `.off` and the keyboard falls back to today's floor flow.

// MARK: - SessionStatusReading

/// Read-only view of the host's mirrored `SessionStatus`. The keyboard reads this
/// (poll + Darwin ping on `SessionDarwinNames.status`) to drive the mic key; it
/// never writes — only the host publishes status.
public protocol SessionStatusReading: Sendable {
    /// The last status the host published, or a fresh `.off` when none exists yet
    /// (missing/corrupt file). Callers still apply the staleness fence via
    /// `SessionStatus.effectivePhase(now:)` — a returned live phase whose heartbeat
    /// is stale collapses to `.off`.
    func read(now: Date) -> SessionStatus
}

// MARK: - AppGroupSessionStatusReader

/// File-based `SessionStatusReading`, reading `session/status.json` (a JSON-encoded
/// `SessionStatus`) from the App Group container's `session/` directory — the same
/// directory the command mailbox and partial store live in. Read-only: it never
/// creates or writes the file (the host owns writes).
public struct AppGroupSessionStatusReader: SessionStatusReading {

    private let statusURL: URL

    /// `directory` is the App Group `session/` subdirectory (see
    /// `SessionEnvironment.live`). The directory is NOT created here — this reader
    /// only reads; the writing side (host) creates it.
    public init(directory: URL) {
        self.statusURL = directory.appendingPathComponent("status.json")
    }

    public func read(now: Date) -> SessionStatus {
        // Missing or corrupt → "no session" (the host hasn't armed, or hasn't wired
        // status yet). `.off(updatedAt: now)` keeps `effectivePhase` at `.off`.
        guard let data = try? Data(contentsOf: statusURL),
              let status = try? JSONDecoder().decode(SessionStatus.self, from: data) else {
            return .off(updatedAt: now)
        }
        return status
    }
}

// MARK: - InMemorySessionStatusReader

/// In-process `SessionStatusReading` double. Preset the status a test wants the
/// keyboard to see; the render/resolve logic still applies the staleness fence.
public final class InMemorySessionStatusReader: SessionStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var status: SessionStatus

    /// Defaults to a fresh `.off` (mirrors the file reader's "no file" result).
    public init(status: SessionStatus = .off(updatedAt: .distantPast)) {
        self.status = status
    }

    /// Set the status the next `read` returns.
    public func set(_ status: SessionStatus) {
        lock.lock(); defer { lock.unlock() }
        self.status = status
    }

    public func read(now: Date) -> SessionStatus {
        lock.lock(); defer { lock.unlock() }
        return status
    }
}
