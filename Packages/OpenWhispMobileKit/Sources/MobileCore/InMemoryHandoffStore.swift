import Foundation

/// In-process, thread-safe `DictationHandoffStore` used by tests and previews.
///
/// It models the exact contract the file-based `AppGroupHandoffStore` (WP5) must
/// satisfy: a single-slot mailbox where `consume` succeeds at most once for a
/// given publish and refuses expired transcripts. A lock stands in for the file
/// system's atomic claim-rename, so racing-consumer tests are meaningful.
public final class InMemoryHandoffStore: DictationHandoffStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: PendingTranscript?

    public init() {}

    public func publish(_ transcript: PendingTranscript) throws {
        lock.lock()
        defer { lock.unlock() }
        pending = transcript
    }

    public func peek() throws -> PendingTranscript? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    public func consume(id: UUID, now: Date) throws -> PendingTranscript? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = pending, current.id == id else {
            // No pending transcript, or a different one — nothing to take.
            return nil
        }
        if current.isExpired(now: now) {
            // Expired transcripts are never handed out. Clear the slot so a
            // stale entry can't linger and be peeked forever.
            pending = nil
            return nil
        }
        // Atomic take: empty the slot so a second consumer gets nil.
        pending = nil
        return current
    }

    public func discardAll() throws {
        lock.lock()
        defer { lock.unlock() }
        pending = nil
    }
}
