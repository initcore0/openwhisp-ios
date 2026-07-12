import Foundation
import OpenWhispCore
import SyncCore

/// Out-of-band pairing (ARCHITECTURE §6.5): the Mac shows a QR, the phone scans
/// it. `completePairing` parses + validates the payload, stores the 32-byte PSK
/// in the Keychain, and persists the (secret-free) ``PeerIdentity``. `unpair`
/// destroys the key and forgets the record.
public protocol PairingService: AnyObject {
    /// Parse a scanned QR payload, store its PSK, persist the peer. Throws
    /// ``PairingPayload/ParseError`` on a bad/garbage/future payload.
    func completePairing(scannedQR: Data) throws -> PeerIdentity
    /// Unpair = key destruction + record removal.
    func unpair(_ peer: PeerIdentity.ID) throws
    var pairedPeers: [PeerIdentity] { get }
    /// Fetch the stored raw PSK for a peer (nil if not paired) — the transport
    /// needs it to arm TLS.
    func psk(for peer: PeerIdentity.ID) -> Data?
}

/// Keychain + JSON-store backed ``PairingService``. `SecretStore` is injected so
/// tests drive it with an `InMemorySecretStore`; the app injects
/// ``KeychainSecretStore``.
public final class DefaultPairingService: PairingService {
    private let secrets: SecretStore
    private let peerStore: PeerStore

    public init(secrets: SecretStore, peerStore: PeerStore = PeerStore()) {
        self.secrets = secrets
        self.peerStore = peerStore
    }

    public func completePairing(scannedQR: Data) throws -> PeerIdentity {
        let payload = try PairingPayload.parse(scannedQR)
        let identity = payload.peerIdentity()
        // Secret first, then the record — if the process dies between, a dangling
        // PSK is harmless (unreferenced) whereas a peer record with no key would
        // fail to sync. Order chosen so the visible record always has a key.
        secrets.save(payload.psk.base64EncodedString(),
                     key: KeychainSecretStore.pskKey(for: payload.peerID))
        peerStore.upsert(identity)
        return identity
    }

    public func unpair(_ peer: PeerIdentity.ID) throws {
        // Key destruction is the security-critical half — do it first, then forget.
        secrets.save("", key: KeychainSecretStore.pskKey(for: peer))   // empty = delete
        peerStore.remove(peer)
    }

    public var pairedPeers: [PeerIdentity] { peerStore.load() }

    public func psk(for peer: PeerIdentity.ID) -> Data? {
        guard let b64 = secrets.read(key: KeychainSecretStore.pskKey(for: peer)) else { return nil }
        return Data(base64Encoded: b64)
    }
}
