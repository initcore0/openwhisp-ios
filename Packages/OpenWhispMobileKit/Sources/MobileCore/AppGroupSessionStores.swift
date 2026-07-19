import Foundation

// MARK: - Concrete session-store conformers (ARCHITECTURE §6.8)
//
// The App Group file stores for the session seam, defined once here (like the
// handoff conformers) so the host, keyboard, and widgets all construct identical
// stores. Same atomicity discipline as `AppGroupHandoffStore`: atomic replace on
// write, `O_EXCL` claim-rename on the mailbox's atomic take.
//
// File layout inside the App Group container (under `session/`):
//   session/command.json          — the single-slot command mailbox
//   session/claimed-<uuid>.json    — a transient claim during take
//   session/partial.json           — the last-writer-wins live partial slot

// MARK: - AppGroupSessionCommandMailbox

/// File-based `SessionCommandMailbox`. `post` replaces `command.json` atomically;
/// `take` CLAIMS the file by renaming it to a per-consumer name first — `rename`
/// is atomic, so exactly one racing `take` wins and the loser sees ENOENT → nil.
/// Expiry is checked after the claim, so an expired command is destroyed (its
/// slot emptied) but never delivered.
public struct AppGroupSessionCommandMailbox: SessionCommandMailbox {

    private let directory: URL
    private var commandURL: URL { directory.appendingPathComponent("command.json") }

    /// `directory` is created on init. Pass the App Group container's `session/`
    /// subdirectory in production (see `SessionEnvironment.live`).
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func post(_ cmd: SessionCommand, now: Date) throws {
        let envelope = SessionCommandEnvelope(command: cmd, postedAt: now)
        let data = try JSONEncoder().encode(envelope)
        let tmp = directory.appendingPathComponent("post-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try SessionFileIO.applyProtection(to: tmp)
        // rename(2) atomically replaces any currently-pending command.
        try SessionFileIO.rename(from: tmp, to: commandURL)
    }

    public func take(now: Date) throws -> SessionCommand? {
        // Claim: an atomic rename to a name only this call knows. If a racing
        // `take` got there first, rename fails → nil.
        let claim = directory.appendingPathComponent("claimed-\(UUID().uuidString).json")
        do {
            try SessionFileIO.rename(from: commandURL, to: claim)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claim) }

        guard let data = try? Data(contentsOf: claim),
              let envelope = try? JSONDecoder().decode(SessionCommandEnvelope.self, from: data) else {
            return nil
        }
        // Expired → destroyed by the claim (a stale startCapture must never fire
        // minutes later), but nothing is delivered.
        guard !envelope.isExpired(now: now) else { return nil }
        return envelope.command
    }
}

// MARK: - AppGroupLivePartialStore

/// File-based `LivePartialStore`: last-writer-wins single file, atomic replace.
/// No claim-rename — the keyboard polls and the host overwrites; the newest write
/// wins (the `seq`/`updatedAt` fields let the reader ignore regressions).
public struct AppGroupLivePartialStore: LivePartialStore {

    private let directory: URL
    private var partialURL: URL { directory.appendingPathComponent("partial.json") }

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ p: LivePartial) throws {
        let data = try JSONEncoder().encode(p)
        let tmp = directory.appendingPathComponent("partial-\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try SessionFileIO.applyProtection(to: tmp)
        try SessionFileIO.rename(from: tmp, to: partialURL)
    }

    public func read() throws -> LivePartial? {
        guard let data = try? Data(contentsOf: partialURL) else { return nil }
        return try? JSONDecoder().decode(LivePartial.self, from: data)
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: partialURL)
    }
}

// MARK: - Shared file helpers

/// The rename + Data Protection helpers, shared by the session stores. Identical
/// discipline to `AppGroupHandoffStore` (kept separate so the two seams don't
/// couple through a private method).
enum SessionFileIO {

    static func rename(from: URL, to: URL) throws {
        let result = from.withUnsafeFileSystemRepresentation { fromPath in
            to.withUnsafeFileSystemRepresentation { toPath in
                Foundation.rename(fromPath!, toPath!)
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Data Protection: readable after first unlock (the keyboard may post a
    /// command while the phone is re-locked mid-flow). iOS-only attribute.
    static func applyProtection(to url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

// MARK: - SessionEnvironment

/// The one way every target obtains the live session stores — host, keyboard, and
/// widgets must all call this so they agree on paths and semantics (mirrors
/// `HandoffEnvironment`). The `SessionStatus` itself rides the existing shared
/// state file surface (WP10b wires it); this environment owns the command mailbox
/// and the partial stream.
public struct SessionEnvironment {
    public let commandMailbox: AppGroupSessionCommandMailbox
    public let partialStore: AppGroupLivePartialStore

    /// nil when the App Group container is unavailable (missing entitlement) —
    /// callers degrade gracefully (session features stay invisible in the keyboard).
    public static func live(appGroupID: String = AppGroup.id) -> SessionEnvironment? {
        guard let container = AppGroup.containerURL(id: appGroupID) else { return nil }
        let dir = container.appendingPathComponent("session", isDirectory: true)
        guard let commandMailbox = try? AppGroupSessionCommandMailbox(directory: dir),
              let partialStore = try? AppGroupLivePartialStore(directory: dir) else { return nil }
        return SessionEnvironment(commandMailbox: commandMailbox, partialStore: partialStore)
    }

    public init(
        commandMailbox: AppGroupSessionCommandMailbox,
        partialStore: AppGroupLivePartialStore
    ) {
        self.commandMailbox = commandMailbox
        self.partialStore = partialStore
    }
}
