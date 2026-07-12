import Foundation

/// A paired device (the user's Mac). Persisted by the host app in a small JSON
/// store; the 32-byte PSK it references lives separately in the Keychain (keyed
/// by `id`), never in this struct — so a leaked `PeerIdentity` reveals no secret,
/// only that a pairing exists and its human-readable fingerprint.
///
/// ARCHITECTURE §6.5 (binding). Foundation-only + `Codable` so it lives in the
/// pure `swift test` surface.
public struct PeerIdentity: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// "Max's MacBook Pro" — shown on the paired-device card.
    public let displayName: String
    /// A short, human-comparable digest of the PSK, shown in the pairing-confirm
    /// UI so a user can eyeball that both devices minted the same key. NOT the
    /// key: it is a truncated SHA-256 of the raw PSK bytes (see
    /// ``PairingPayload/fingerprint(forPSK:)``), one-way and safe to persist.
    public let pskFingerprint: String
    /// The Bonjour service instance name the Mac advertises under
    /// `_openwhisp._tcp` (from the QR). Lets the browser match the RIGHT peer when
    /// several Macs are on the LAN, without connecting to guess.
    public let serviceInstance: String
    /// Last successful sync (nil = never). Advanced by the host app after a run.
    public var lastSeen: Date?

    public init(
        id: UUID,
        displayName: String,
        pskFingerprint: String,
        serviceInstance: String,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.pskFingerprint = pskFingerprint
        self.serviceInstance = serviceInstance
        self.lastSeen = lastSeen
    }

    // Tolerant decode: `lastSeen` optional (a freshly-paired record has none), and
    // `serviceInstance` defaults to "" for any record written before the field
    // existed — a browser then falls back to matching on displayName.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.pskFingerprint = try c.decode(String.self, forKey: .pskFingerprint)
        self.serviceInstance = try c.decodeIfPresent(String.self, forKey: .serviceInstance) ?? ""
        self.lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
    }
}
