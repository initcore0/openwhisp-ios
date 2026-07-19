import Foundation

// MARK: - SessionStatus store (ARCHITECTURE §6.8) — the sanctioned WP10a-gap fill
//
// §6.8 says the `SessionStatus` "rides the shared-state surface": the host mirrors
// its session phase into the App Group for the keyboard to read, heartbeating while
// armed so a stale status (a jetsammed host) collapses to `.off` on the reader side
// (`SessionStatus.effectivePhase`). WP10a shipped the `SessionStatus` value type and
// the staleness rule but NO dedicated store — the driver (WP10b) is the first thing
// that must actually publish a status, so the store lands here.
//
// This is deliberately a SEPARATE single-slot file (`session/status.json`) rather
// than a new field on `FileSharedStateStore`'s blob: the session status is written
// far more often (a ≥ 1/15 s heartbeat, plus a write on every phase change) than the
// keyboard config, and a distinct file keeps the two write cadences from contending
// on one blob's read-modify-write. It follows the same discipline as the other
// session stores (atomic replace, Data Protection, last-writer-wins).
//
// The whole thing is Foundation-only so it compiles into the keyboard extension too
// (the keyboard READS the status to resolve its mic key; only the host writes it).

// MARK: - SessionStatusStore

/// Last-writer-wins single-slot session-status store (host writes, keyboard reads).
/// No atomic claim-rename — the host overwrites and the keyboard polls; the newest
/// write wins and the reader folds in the 30 s staleness rule
/// (`SessionStatus.effectivePhase(now:)`) itself.
///
/// Concrete conformer: `AppGroupSessionStatusStore` (file-based, atomic replace).
/// Test double: `InMemorySessionStatusStore`.
public protocol SessionStatusStore: Sendable {
    /// Overwrite the current status (host side; called on every phase change and on
    /// the heartbeat).
    func write(_ status: SessionStatus) throws
    /// Read the last-written status, or `nil` when none has been written yet. The
    /// reader applies staleness itself via `effectivePhase(now:)`.
    func read() throws -> SessionStatus?
    /// Remove the status entirely (equivalent to "no session was ever armed"). Used
    /// on teardown so a leftover `.off` heartbeat doesn't linger; reading an absent
    /// status is `nil`, which callers treat exactly as `.off`.
    func clear() throws
}

// MARK: - AppGroupSessionStatusStore

/// File-based `SessionStatusStore`: `session/status.json`, atomic replace, Data
/// Protection `.completeUntilFirstUserAuthentication` (the keyboard reads it after
/// first unlock while the phone is re-locked mid-flow). Reuses `SessionFileIO`.
public struct AppGroupSessionStatusStore: SessionStatusStore {

    private let directory: URL
    private var statusURL: URL { directory.appendingPathComponent("status.json") }

    /// `directory` is created on init. Pass the App Group container's `session/`
    /// subdirectory in production (see `SessionEnvironment.live`).
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ status: SessionStatus) throws {
        let data = try JSONEncoder().encode(status)
        let tmp = directory.appendingPathComponent("status-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try SessionFileIO.applyProtection(to: tmp)
        try SessionFileIO.rename(from: tmp, to: statusURL)
    }

    public func read() throws -> SessionStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(SessionStatus.self, from: data)
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: statusURL)
    }
}

// MARK: - InMemorySessionStatusStore

/// In-process `SessionStatusStore`: a last-writer-wins single slot. Models the exact
/// contract the file store satisfies so the driver (WP10b) and keyboard (WP10c) can
/// be built and tested against it before the real store exists.
public final class InMemorySessionStatusStore: SessionStatusStore, @unchecked Sendable {
    private let lock = NSLock()
    private var status: SessionStatus?

    public init() {}

    public func write(_ status: SessionStatus) throws {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
    }

    public func read() throws -> SessionStatus? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        status = nil
    }
}
