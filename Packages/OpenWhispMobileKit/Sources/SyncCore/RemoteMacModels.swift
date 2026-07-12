import Foundation
import OpenWhispCore

/// A history row as the phone's "browse your Mac's history" list renders it — the
/// wire `HistoryEntryDTO` cleaned up for display: the ISO-8601 `date` string
/// parsed to a `Date` (nil-tolerant), the initiator normalized to an enum, and an
/// app label chosen from `appName`/`appBundleID`.
///
/// Pure + tested: `RemoteMacClient` returns the raw `[HistoryEntryDTO]`, and this
/// view model is derived here so the mapping (parse failures, missing fields,
/// initiator normalization) is covered without a device.
public struct RemoteHistoryItem: Identifiable, Equatable, Sendable {
    public enum Initiator: String, Equatable, Sendable {
        case user, agent, unknown
    }

    public let id: UUID
    public let text: String
    /// Parsed from the wire ISO-8601 string; nil if it didn't parse (the row
    /// still shows, just without a timestamp).
    public let date: Date?
    public let appName: String?
    public let appBundleID: String?
    public let initiator: Initiator

    public init(
        id: UUID, text: String, date: Date?, appName: String?,
        appBundleID: String?, initiator: Initiator
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.appName = appName
        self.appBundleID = appBundleID
        self.initiator = initiator
    }

    /// A short label for the source app: the friendly name if present, else the
    /// bundle id, else nil (no app attribution).
    public var appLabel: String? {
        if let appName, !appName.isEmpty { return appName }
        if let appBundleID, !appBundleID.isEmpty { return appBundleID }
        return nil
    }

    /// Build from a wire DTO. `date` uses the same ISO-8601 helper the Mac encodes
    /// with (`BridgeWire.iso8601String`), so a round-trip is lossless; an
    /// unparseable/empty string yields a nil `date` rather than dropping the row.
    public init(dto: BridgeWire.HistoryEntryDTO) {
        self.id = dto.id
        self.text = dto.text
        self.date = RemoteHistoryItem.parseDate(dto.date)
        self.appName = dto.appName
        self.appBundleID = dto.appBundleID
        self.initiator = RemoteHistoryItem.initiator(from: dto.initiator)
    }

    /// Map a whole wire result to display rows, preserving the Mac's order
    /// (newest-first, as the bridge returns them).
    public static func list(from result: BridgeWire.HistoryListResult) -> [RemoteHistoryItem] {
        result.entries.map(RemoteHistoryItem.init(dto:))
    }

    static func initiator(from raw: String?) -> Initiator {
        switch raw?.lowercased() {
        case "user": return .user
        case "agent": return .agent
        default: return .unknown
        }
    }

    /// Parse the wire's ISO-8601 timestamp. Tries fractional-seconds first (what
    /// `BridgeWire.iso8601String` emits), then plain ISO-8601, so both encodings
    /// round-trip. Returns nil on empty/garbage.
    static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// The phone-side view of a remote dictation's lifecycle while a blocking
/// `dictate` call runs on the Mac. Drives the "listening on your Mac…" surface.
/// Distinct from `BridgeWire.DictateState` (the wire notification) so the UI has
/// a stable, exhaustive set that also models the terminal + idle phases the wire
/// enum doesn't carry.
public enum RemoteDictationPhase: Equatable, Sendable {
    /// No remote dictation in flight.
    case idle
    /// The call is out; the Mac is deciding consent / warming up.
    case requesting
    /// The Mac is listening on its mic (the human should speak there).
    case listening
    /// The Mac is transcribing / refining the captured audio.
    case working
    /// Finished with text (the human's spoken answer / dictation).
    case finished(text: String)
    /// Finished in a failure the UI should surface.
    case failed(RemoteMacError)

    /// Fold a wire `dictate.state` notification into a coarse phase. Unknown
    /// future states default to `.working` (a benign "something's happening").
    public static func from(wire state: BridgeWire.DictateState) -> RemoteDictationPhase {
        switch state {
        case .consentPending, .starting: return .requesting
        case .listening:                 return .listening
        case .transcribing, .refining:   return .working
        }
    }

    /// True while the Mac is actively engaged (used to gate the "in progress" UI
    /// and disable re-entrant taps).
    public var isBusy: Bool {
        switch self {
        case .requesting, .listening, .working: return true
        case .idle, .finished, .failed: return false
        }
    }
}
