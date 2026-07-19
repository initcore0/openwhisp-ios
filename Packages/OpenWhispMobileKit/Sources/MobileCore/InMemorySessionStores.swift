import Foundation

// MARK: - In-memory session-store doubles (ARCHITECTURE §6.8)
//
// The test/preview doubles for the session seam. They model the EXACT contract
// the file-based App Group conformers must satisfy — a single-slot, single-
// consumer command mailbox with 5 s expiry, and a last-writer-wins partial slot —
// so the driver (WP10b) and keyboard (WP10c) can be built and tested against them
// before the real stores exist. Locks stand in for the file system's atomic
// claim-rename so racing-consumer tests are meaningful.

/// In-process `SessionCommandMailbox`. A lock stands in for the file system's
/// atomic claim-rename, so exactly one racing `take` wins.
public final class InMemorySessionCommandMailbox: SessionCommandMailbox, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: SessionCommandEnvelope?

    public init() {}

    public func post(_ cmd: SessionCommand, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        pending = SessionCommandEnvelope(command: cmd, postedAt: now)
    }

    public func take(now: Date) throws -> SessionCommand? {
        lock.lock()
        defer { lock.unlock() }
        guard let envelope = pending else { return nil }
        // Atomic take: empty the slot so a second consumer gets nil.
        pending = nil
        // Expired commands are destroyed by the take, never delivered.
        guard !envelope.isExpired(now: now) else { return nil }
        return envelope.command
    }
}

/// In-process `LivePartialStore`: a last-writer-wins single slot.
public final class InMemoryLivePartialStore: LivePartialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var partial: LivePartial?

    public init() {}

    public func write(_ p: LivePartial) throws {
        lock.lock()
        defer { lock.unlock() }
        partial = p
    }

    public func read() throws -> LivePartial? {
        lock.lock()
        defer { lock.unlock() }
        return partial
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        partial = nil
    }
}
