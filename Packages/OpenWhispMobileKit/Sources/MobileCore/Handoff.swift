import Foundation

// MARK: - Handoff (ARCHITECTURE §6.1) — the load-bearing seam
//
// A finished, cleaned transcript flows from the host app to the keyboard through
// the App Group container ONLY (decision D7). These types define that contract.
// They are Foundation-only so they compile into both the host app and the
// (memory-tight) keyboard extension, and so the whole seam is `swift test`-able
// without any OS surface.

/// A finished, cleaned transcript the host publishes for the keyboard to insert.
///
/// The `text` is ALREADY post-processed — `TranscriptCleaner` ran in the host
/// before publish, because the keyboard extension has neither the mic nor the
/// engine to do it (constraint C1). The keyboard's only job is insertion.
public struct PendingTranscript: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// ALREADY post-processed (TranscriptCleaner ran in the host).
    public let text: String
    public let createdAt: Date
    /// `createdAt + 120s`; never insert past this. Guards against a stale
    /// dictation landing into tomorrow's password field (ARCHITECTURE §5).
    public let expiresAt: Date
    public let source: Source

    public enum Source: String, Codable, Sendable {
        case appIntent
        case appSwitch
        case inApp
    }

    /// The standard handoff lifetime: a transcript expires 120 seconds after it
    /// was created (decision D7).
    public static let defaultLifetime: TimeInterval = 120

    public init(
        id: UUID,
        text: String,
        createdAt: Date,
        expiresAt: Date,
        source: Source
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.source = source
    }

    /// Convenience initializer that stamps `expiresAt = createdAt + defaultLifetime`.
    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date,
        source: Source,
        lifetime: TimeInterval = PendingTranscript.defaultLifetime
    ) {
        self.init(
            id: id,
            text: text,
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(lifetime),
            source: source
        )
    }

    /// True when `now` is at or after `expiresAt`.
    public func isExpired(now: Date) -> Bool {
        now >= expiresAt
    }
}

/// Atomic single-consumer mailbox in the App Group container.
///
/// Concrete conformer (WP5): `AppGroupHandoffStore` — file-based, `O_EXCL`
/// claim-rename for an atomic consume, Data Protection
/// `.completeUntilFirstUserAuthentication`.
/// Test double (this WP): `InMemoryHandoffStore`.
public protocol DictationHandoffStore: Sendable {
    /// Publish a transcript, replacing any currently-pending one.
    func publish(_ transcript: PendingTranscript) throws
    /// Return the pending transcript without consuming it (nil if none).
    func peek() throws -> PendingTranscript?
    /// Atomically take the transcript iff `id` matches the pending one AND it is
    /// unexpired. Returns nil when it was already consumed, does not match, or
    /// has expired. On success the mailbox is emptied.
    func consume(id: UUID, now: Date) throws -> PendingTranscript?
    /// Empty the mailbox unconditionally.
    func discardAll() throws
}

/// Cross-process "new transcript" ping.
///
/// Concrete conformer (WP5): `DarwinHandoffNotifier` —
/// `CFNotificationCenterGetDarwinNotifyCenter`, name
/// `"app.openwhisp.handoff.published"`. The notification carries NO payload; the
/// keyboard reads the store on receipt. The fallback path is a store read on the
/// keyboard's `viewWillAppear` (Darwin notifications are best-effort).
public protocol HandoffNotifier: AnyObject {
    /// Fire the cross-process ping. Called by the host after `publish`.
    func notifyPublished()
    /// Invoked (on the receiving process) when a ping arrives.
    var onPublished: (() -> Void)? { get set }
}

// MARK: - Shared state (host ⇄ keyboard flags)

/// The capture pipeline's coarse state, as the keyboard needs to see it to
/// resolve the mic key (D8). Distinct from the richer `CaptureState` used inside
/// the host — this is the small, cross-process-shared slice.
public enum HandoffCaptureState: String, Codable, Equatable, Sendable {
    case idle
    case capturing
    case transcribing
}

/// The keyboard's user-picked configuration, persisted by the host through the
/// App Group so both processes agree. Per-app modes degrade on iOS (a keyboard
/// cannot identify its host app), so `mode` is user-picked, never auto-applied
/// silently (ARCHITECTURE §6.4).
public struct KeyboardConfig: Codable, Equatable, Sendable {
    /// The user-selected dictation mode identifier (e.g. "default", "email").
    /// Free-form string keyed to an upstream `AppProfile`/mode; the keyboard
    /// never invents modes, it only selects among configured ones.
    public var mode: String
    /// Whether key-press haptics are enabled (only where the extension is
    /// permitted to vibrate).
    public var haptics: Bool
    /// Whether automatic capitalization after sentence breaks is enabled.
    public var autocap: Bool

    public static let `default` = KeyboardConfig(mode: "default", haptics: true, autocap: true)

    public init(mode: String, haptics: Bool, autocap: Bool) {
        self.mode = mode
        self.haptics = haptics
        self.autocap = autocap
    }
}

/// Host ⇄ keyboard shared flags (also the App Group; a small audited JSON file,
/// deliberately NOT `UserDefaults`, to keep one inspectable file format).
/// Carries the capture state for the mic key, the selected mode, and the
/// keyboard settings snapshot.
public protocol SharedStateStore: Sendable {
    func readCaptureState() -> HandoffCaptureState      // idle | capturing | transcribing
    func writeCaptureState(_ s: HandoffCaptureState)
    func readKeyboardConfig() -> KeyboardConfig          // mode, haptics, autocap…
    func writeKeyboardConfig(_ c: KeyboardConfig)
}
