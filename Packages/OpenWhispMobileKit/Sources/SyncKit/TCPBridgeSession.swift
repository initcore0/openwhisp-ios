import Foundation
import Network
import OpenWhispCore
import OpenWhispBridgeKit

/// A ``BridgeSession`` (upstream BridgeKit protocol) that speaks the Agent Bridge
/// NDJSON JSON-RPC over a TLS-PSK `NWConnection` instead of the Mac's UNIX socket
/// (ARCHITECTURE §6.5: "the wire IS the Agent Bridge, over TLS/TCP"). Because the
/// upstream `PersistentBridge`/MCP plumbing is written against `BridgeSession`,
/// they work unchanged over the LAN.
///
/// The protocol is synchronous-throwing, so each `call` writes a frame and blocks
/// on the underlying ``NDJSONConnection`` for the matching response. Sync is a
/// foreground, request/response affair (no server-push mid-call), so a strict
/// one-in-flight-at-a-time model is correct and simple.
public final class TCPBridgeSession: BridgeSession {
    public enum SessionError: Error, Equatable {
        case notConnected
        case transport(String)
        case undecodable(String)
        case domain(reason: BridgeWire.ErrorCode?, message: String)
        case unsupportedVersion
    }

    private let connection: NDJSONConnection
    private let callTimeout: TimeInterval
    private let clientVersion: String
    private var nextID = 0
    private let lock = NSLock()

    /// The response envelope, decoded per-call (mirrors BridgeClient's private one).
    private struct ResponseEnvelope<T: Decodable>: Decodable {
        let jsonrpc: String?
        let id: BridgeWire.RPCID?
        let result: T?
        let error: BridgeWire.ErrorObject?
    }

    init(connection: NDJSONConnection, callTimeout: TimeInterval = 30, clientVersion: String = "0.1.0") {
        self.connection = connection
        self.callTimeout = callTimeout
        self.clientVersion = clientVersion
    }

    // MARK: BridgeSession

    /// Perform the mandatory `bridge.hello` handshake, advertising this client and
    /// verifying the peer offers the `sync` capability.
    public func handshake(clientName: String) throws {
        let params = BridgeWire.HelloParams(
            protocolVersion: BridgeWire.protocolVersion,
            clientName: clientName,
            clientVersion: clientVersion,
            parentProcess: nil
        )
        let result: BridgeWire.HelloResult = try call(
            method: BridgeWire.Method.hello.rawValue, params: params,
            resultType: BridgeWire.HelloResult.self)
        guard result.capabilities.contains(BridgeWire.Capability.sync) else {
            throw SessionError.domain(
                reason: .unknownMethod,
                message: "paired Mac does not offer the 'sync' capability (update OpenWhisp on the Mac)")
        }
    }

    public func call<P: Codable & Sendable, R: Decodable>(
        method: String, params: P?, resultType: R.Type
    ) throws -> R {
        lock.lock(); nextID += 1; let id = nextID; lock.unlock()

        let request = BridgeWire.Request(id: .number(id), method: method, params: params)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(request)
        } catch {
            throw SessionError.undecodable("encode request: \(error.localizedDescription)")
        }

        do {
            try connection.writeFrame(payload)
            let line = try connection.readFrame(timeout: callTimeout)
            let resp = try JSONDecoder().decode(ResponseEnvelope<R>.self, from: line)
            if let err = resp.error {
                if err.data?.reason == .unsupportedVersion { throw SessionError.unsupportedVersion }
                throw SessionError.domain(reason: err.data?.reason, message: err.message)
            }
            guard let result = resp.result else {
                throw SessionError.undecodable("response had neither result nor error")
            }
            return result
        } catch let e as SessionError {
            throw e
        } catch let e as NDJSONConnection.ConnError {
            throw SessionError.transport("\(e)")
        } catch {
            throw SessionError.undecodable(error.localizedDescription)
        }
    }

    public func close() { connection.cancel() }
}
