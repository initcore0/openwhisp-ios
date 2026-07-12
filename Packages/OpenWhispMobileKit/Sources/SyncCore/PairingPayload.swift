import Foundation
import CryptoKit

/// The out-of-band pairing payload the Mac encodes into the QR code and the phone
/// scans (ARCHITECTURE §6.5). Shape is fixed by the WP6-mac minting side:
///
///     { "version": 1,
///       "peerID": "<UUID>",
///       "displayName": "Max's MacBook Pro",
///       "psk": "<base64 of 32 random bytes>",
///       "serviceInstance": "OpenWhisp-abc123" }
///
/// Parse is deliberately strict about the security-critical fields (a malformed
/// or wrong-length PSK, a bad UUID, or a future `version` all throw) and lenient
/// about nothing that would weaken the key. The PSK never persists inside a
/// ``PeerIdentity`` — the caller hands it to the Keychain and keeps only the
/// fingerprint.
public struct PairingPayload: Equatable, Sendable {
    /// The only version this build understands. A newer QR (version 2+) is
    /// rejected with `.unsupportedVersion` so we never half-parse a shape we don't
    /// know — the user is told to update the app.
    public static let currentVersion = 1

    /// Expected PSK length in bytes (32 = 256-bit, minted at pairing).
    public static let pskByteCount = 32

    public let version: Int
    public let peerID: UUID
    public let displayName: String
    /// The raw 32-byte pre-shared key. Held only transiently by the caller
    /// (pairing → Keychain); never encoded into a persisted model.
    public let psk: Data
    public let serviceInstance: String

    public init(version: Int, peerID: UUID, displayName: String, psk: Data, serviceInstance: String) {
        self.version = version
        self.peerID = peerID
        self.displayName = displayName
        self.psk = psk
        self.serviceInstance = serviceInstance
    }

    public enum ParseError: Error, Equatable {
        /// The scanned data wasn't a JSON object with the expected keys.
        case malformed(String)
        /// `version` is newer than this build understands.
        case unsupportedVersion(found: Int, supported: Int)
        /// `psk` wasn't valid base64, or decoded to the wrong number of bytes.
        case invalidPSK(String)
        /// `peerID` wasn't a valid UUID.
        case invalidPeerID(String)
    }

    // The wire keys. `serviceInstance` also accepts a couple of spellings the
    // minting side might emit ("service", "service_instance") so a trivial naming
    // drift between the two independently-written sides doesn't wedge pairing.
    private struct Wire: Decodable {
        let version: Int
        let peerID: String
        let displayName: String
        let psk: String
        let serviceInstance: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try c.decode(Int.self, forKey: .version)
            self.peerID = try c.decode(String.self, forKey: .peerID)
            self.displayName = try c.decode(String.self, forKey: .displayName)
            self.psk = try c.decode(String.self, forKey: .psk)
            if let s = try c.decodeIfPresent(String.self, forKey: .serviceInstance) {
                self.serviceInstance = s
            } else if let s = try c.decodeIfPresent(String.self, forKey: .service) {
                self.serviceInstance = s
            } else if let s = try c.decodeIfPresent(String.self, forKey: .service_instance) {
                self.serviceInstance = s
            } else {
                self.serviceInstance = ""
            }
        }

        enum CodingKeys: String, CodingKey {
            case version, peerID, displayName, psk
            case serviceInstance, service, service_instance
        }
    }

    /// Parse + validate a scanned QR payload. Throws ``ParseError`` on any problem;
    /// on success the returned value carries a well-formed 32-byte PSK.
    public static func parse(_ data: Data) throws -> PairingPayload {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw ParseError.malformed(error.localizedDescription)
        }

        guard wire.version <= currentVersion else {
            throw ParseError.unsupportedVersion(found: wire.version, supported: currentVersion)
        }
        // A version < 1 (or 0) is not a shape we ever minted — reject as malformed.
        guard wire.version >= 1 else {
            throw ParseError.malformed("version \(wire.version) < 1")
        }
        guard let peerID = UUID(uuidString: wire.peerID) else {
            throw ParseError.invalidPeerID(wire.peerID)
        }
        guard let psk = Data(base64Encoded: wire.psk) else {
            throw ParseError.invalidPSK("not base64")
        }
        guard psk.count == pskByteCount else {
            throw ParseError.invalidPSK("expected \(pskByteCount) bytes, got \(psk.count)")
        }

        return PairingPayload(
            version: wire.version,
            peerID: peerID,
            displayName: wire.displayName,
            psk: psk,
            serviceInstance: wire.serviceInstance
        )
    }

    /// A short, human-comparable fingerprint of a PSK: the first 8 bytes of its
    /// SHA-256, hex, grouped in pairs ("a1 b2 c3 d4 e5 f6 07 18"). One-way — safe
    /// to persist in ``PeerIdentity`` and show on the confirm screen so the user
    /// can verify both devices minted the same key.
    public static func fingerprint(forPSK psk: Data) -> String {
        let digest = SHA256.hash(data: psk)
        let head = Array(digest.prefix(8))
        return head.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// This payload's PSK fingerprint.
    public var pskFingerprint: String { Self.fingerprint(forPSK: psk) }

    /// Build the persistable ``PeerIdentity`` for this payload (PSK excluded).
    public func peerIdentity(lastSeen: Date? = nil) -> PeerIdentity {
        PeerIdentity(
            id: peerID,
            displayName: displayName,
            pskFingerprint: pskFingerprint,
            serviceInstance: serviceInstance,
            lastSeen: lastSeen
        )
    }
}
