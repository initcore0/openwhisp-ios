import Foundation
import Network
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore

/// A peer found on the LAN by Bonjour, before we connect.
public struct DiscoveredPeer: Equatable, Sendable {
    /// The Bonjour service instance name (matches ``PeerIdentity/serviceInstance``).
    public let serviceInstance: String
    /// The resolvable endpoint to connect to.
    public let endpoint: NWEndpoint
    public init(serviceInstance: String, endpoint: NWEndpoint) {
        self.serviceInstance = serviceInstance
        self.endpoint = endpoint
    }
}

/// Cancels an in-flight discovery browse.
public final class DiscoveryToken {
    private let onCancel: () -> Void
    private var cancelled = false
    init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    public func cancel() { guard !cancelled else { return }; cancelled = true; onCancel() }
    deinit { cancel() }
}

/// Bonjour discovery + TLS-PSK connection (ARCHITECTURE §6.5). `connect(to:)`
/// browses for the peer's advertised `_openwhisp._tcp` instance, resolves it,
/// arms TLS with the paired PSK, and returns a handshaked ``BridgeSession`` — the
/// upstream conformer, so all bridge/MCP plumbing works unchanged over the LAN.
public protocol PeerTransport: AnyObject {
    func discover(onFound: @escaping (DiscoveredPeer) -> Void) -> DiscoveryToken
    /// Resolve + connect to `peer` using its stored `psk`, returning a live,
    /// handshaked session. `clientName` is advertised in `bridge.hello`.
    func connect(to peer: PeerIdentity, psk: Data, clientName: String) throws -> any BridgeSession
}

public final class BonjourPeerTransport: PeerTransport {
    public static let serviceType = "_openwhisp._tcp"

    private let connectTimeout: TimeInterval
    private let browseTimeout: TimeInterval

    public init(connectTimeout: TimeInterval = 10, browseTimeout: TimeInterval = 6) {
        self.connectTimeout = connectTimeout
        self.browseTimeout = browseTimeout
    }

    // MARK: Discovery

    public func discover(onFound: @escaping (DiscoveredPeer) -> Void) -> DiscoveryToken {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                onFound(DiscoveredPeer(serviceInstance: name, endpoint: result.endpoint))
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
        return DiscoveryToken { browser.cancel() }
    }

    // MARK: Connect

    public func connect(to peer: PeerIdentity, psk: Data, clientName: String) throws -> any BridgeSession {
        let endpoint = try resolveEndpoint(for: peer)
        let params = TLSPSK.parameters(psk: psk, identityHint: peer.id.uuidString)
        let ndjson = NDJSONConnection(endpoint: endpoint, parameters: params)
        try ndjson.start(timeout: connectTimeout)
        let session = TCPBridgeSession(connection: ndjson)
        try session.handshake(clientName: clientName)
        return session
    }

    /// Browse until the peer's advertised instance appears, then hand back its
    /// endpoint. Bonjour resolution (name → host/port) happens inside
    /// `NWConnection` when we connect, so returning the `.service` endpoint is
    /// enough. Throws `.peerNotFound` if the browse window expires.
    private func resolveEndpoint(for peer: PeerIdentity) throws -> NWEndpoint {
        let sem = DispatchSemaphore(value: 0)
        let found = LockedBox<NWEndpoint?>(nil)
        let token = discover { discovered in
            // Match the exact advertised instance; if the record predates the
            // serviceInstance field (empty), fall back to a displayName match on
            // the leading token so an older pairing still resolves.
            let matches = !peer.serviceInstance.isEmpty
                ? discovered.serviceInstance == peer.serviceInstance
                : discovered.serviceInstance.contains(peer.displayName)
            if matches, found.value == nil {
                found.value = discovered.endpoint
                sem.signal()
            }
        }
        defer { token.cancel() }
        if sem.wait(timeout: .now() + browseTimeout) == .timedOut {
            throw TransportError.peerNotFound(peer.serviceInstance)
        }
        guard let endpoint = found.value else {
            throw TransportError.peerNotFound(peer.serviceInstance)
        }
        return endpoint
    }

    public enum TransportError: Error, Equatable {
        case peerNotFound(String)
    }
}

/// A tiny thread-safe box for handing a value out of a Bonjour callback.
private final class LockedBox<T> {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
