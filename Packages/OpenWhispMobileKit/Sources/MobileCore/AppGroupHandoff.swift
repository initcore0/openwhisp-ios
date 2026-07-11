import Foundation

// MARK: - Concrete handoff conformers (ARCHITECTURE §6.1, seeded for WP4/WP5)
//
// The host app, the keyboard extension, and the widgets extension must all
// construct the SAME concrete store or the handoff silently never happens —
// so the live conformers are defined once here, not per-target.
//
// File layout inside the App Group container:
//   handoff/pending.json        — the single-slot mailbox (atomic replace)
//   handoff/claimed-<uuid>.json — a transient claim during consume
//   handoff/shared-state.json   — HandoffCaptureState + KeyboardConfig

/// The App Group shared by the app + extensions (project.yml entitlements).
public enum AppGroup {
    public static let id = "group.app.openwhisp.ios"

    /// The shared container URL, nil when the process lacks the entitlement
    /// (e.g. `swift test` on the host Mac — tests inject a temp directory).
    public static func containerURL(id: String = AppGroup.id) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}

// MARK: - AppGroupHandoffStore

/// File-based `DictationHandoffStore` over a directory (the App Group container
/// in production, a temp directory in tests).
///
/// Atomicity: `publish` replaces `pending.json` atomically (write-temp +
/// `rename(2)`); `consume` CLAIMS the file by renaming it to a per-consumer
/// name first — `rename` is atomic, so exactly one racing consumer wins and
/// the loser sees ENOENT and returns nil. Expiry is checked after the claim,
/// so an expired transcript is destroyed, never delivered.
public struct AppGroupHandoffStore: DictationHandoffStore {

    private let directory: URL
    private var pendingURL: URL { directory.appendingPathComponent("pending.json") }

    /// `directory` is created on init. Pass the App Group container's
    /// `handoff/` subdirectory in production (see `HandoffEnvironment.live`).
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func publish(_ transcript: PendingTranscript) throws {
        let data = try JSONEncoder().encode(transcript)
        let tmp = directory.appendingPathComponent("publish-\(transcript.id.uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        try Self.applyProtection(to: tmp)
        // rename(2) atomically replaces any currently-pending transcript.
        try Self.rename(from: tmp, to: pendingURL)
    }

    public func peek() throws -> PendingTranscript? {
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        return try? JSONDecoder().decode(PendingTranscript.self, from: data)
    }

    public func consume(id: UUID, now: Date) throws -> PendingTranscript? {
        // Pre-check without claiming: asking for a stale id must NOT destroy a
        // newer pending transcript (matches InMemoryHandoffStore's contract).
        guard let peeked = try peek(), peeked.id == id else { return nil }

        // Claim: an atomic rename to a name only this call knows. If a racing
        // consumer (or discardAll) got there first, rename fails → nil.
        let claim = directory.appendingPathComponent("claimed-\(UUID().uuidString).json")
        do {
            try Self.rename(from: pendingURL, to: claim)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: claim) }

        guard let data = try? Data(contentsOf: claim),
              let transcript = try? JSONDecoder().decode(PendingTranscript.self, from: data) else {
            return nil
        }
        if transcript.id != id {
            // The slot was replaced between peek and claim: we grabbed a NEWER
            // transcript by accident. Put it back — but only if no even-newer
            // publish landed meanwhile (RENAME_EXCL keeps the newest).
            _ = try? Self.renameExclusive(from: claim, to: pendingURL)
            return nil
        }
        // Expired → destroyed by the claim (a stale transcript must never
        // linger), but nothing is delivered.
        guard !transcript.isExpired(now: now) else { return nil }
        return transcript
    }

    public func discardAll() throws {
        try? FileManager.default.removeItem(at: pendingURL)
    }

    // MARK: helpers

    private static func rename(from: URL, to: URL) throws {
        let result = from.withUnsafeFileSystemRepresentation { fromPath in
            to.withUnsafeFileSystemRepresentation { toPath in
                Foundation.rename(fromPath!, toPath!)
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Atomic rename that FAILS if the destination exists (Darwin `renamex_np`
    /// + `RENAME_EXCL`) — used to restore an accidentally-claimed newer
    /// transcript without clobbering an even-newer publish.
    private static func renameExclusive(from: URL, to: URL) throws {
        let result = from.withUnsafeFileSystemRepresentation { fromPath in
            to.withUnsafeFileSystemRepresentation { toPath in
                renamex_np(fromPath!, toPath!, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Data Protection: readable after first unlock (the keyboard may consume
    /// while the phone is re-locked mid-flow). iOS-only attribute.
    private static func applyProtection(to url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }
}

// MARK: - DarwinHandoffNotifier

/// Cross-process ping via the Darwin notify center. No payload — receivers read
/// the store. Best-effort by design; the keyboard's `viewWillAppear` store read
/// is the reliability floor.
public final class DarwinHandoffNotifier: HandoffNotifier, @unchecked Sendable {

    public static let notificationName = "app.openwhisp.handoff.published"

    public var onPublished: (() -> Void)?

    public init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinHandoffNotifier>.fromOpaque(observer).takeUnretainedValue()
                me.onPublished?()
            },
            Self.notificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    public func notifyPublished() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.notificationName as CFString),
            nil, nil, true
        )
    }
}

// MARK: - FileSharedStateStore

/// File-based `SharedStateStore`: one small JSON file, deliberately not
/// UserDefaults, so the entire cross-process surface stays inspectable.
public struct FileSharedStateStore: SharedStateStore {

    private struct Blob: Codable {
        var captureState: HandoffCaptureState
        var keyboardConfig: KeyboardConfig
    }

    private let fileURL: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("shared-state.json")
    }

    public func readCaptureState() -> HandoffCaptureState { read().captureState }

    public func writeCaptureState(_ s: HandoffCaptureState) {
        var blob = read()
        blob.captureState = s
        write(blob)
    }

    public func readKeyboardConfig() -> KeyboardConfig { read().keyboardConfig }

    public func writeKeyboardConfig(_ c: KeyboardConfig) {
        var blob = read()
        blob.keyboardConfig = c
        write(blob)
    }

    private func read() -> Blob {
        guard let data = try? Data(contentsOf: fileURL),
              let blob = try? JSONDecoder().decode(Blob.self, from: data) else {
            // Missing or corrupt → safe defaults (idle; default keyboard config).
            return Blob(captureState: .idle, keyboardConfig: .default)
        }
        return blob
    }

    private func write(_ blob: Blob) {
        guard let data = try? JSONEncoder().encode(blob) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - HandoffEnvironment

/// The one way every target obtains the live handoff pieces — host, keyboard,
/// and widgets must all call this so they agree on paths and semantics.
public struct HandoffEnvironment {
    public let store: AppGroupHandoffStore
    public let notifier: DarwinHandoffNotifier
    public let sharedState: FileSharedStateStore

    /// nil when the App Group container is unavailable (missing entitlement) —
    /// callers degrade gracefully (keyboard: mic key shows the explainer).
    public static func live(appGroupID: String = AppGroup.id) -> HandoffEnvironment? {
        guard let container = AppGroup.containerURL(id: appGroupID) else { return nil }
        let dir = container.appendingPathComponent("handoff", isDirectory: true)
        guard let store = try? AppGroupHandoffStore(directory: dir),
              let sharedState = try? FileSharedStateStore(directory: dir) else { return nil }
        return HandoffEnvironment(store: store, notifier: DarwinHandoffNotifier(), sharedState: sharedState)
    }

    public init(store: AppGroupHandoffStore, notifier: DarwinHandoffNotifier, sharedState: FileSharedStateStore) {
        self.store = store
        self.notifier = notifier
        self.sharedState = sharedState
    }
}
