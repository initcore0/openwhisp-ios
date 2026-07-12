import XCTest
import Foundation
import Network
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore
@testable import SyncKit

/// Proves the TLS 1.3 PSK handshake itself, hermetically: an in-process server
/// armed with the SAME 32-byte PSK as the client, on 127.0.0.1. No external
/// harness — this is the always-green counterpart to ``LoopbackSyncE2ETests``,
/// so a regression in ``TLSPSK`` (cipher suite, version pin, key wiring) is
/// caught in the fast gate rather than only when a Mac is present.
final class TLSPSKLoopbackTests: XCTestCase {

    private func psk() -> Data { Data((0..<32).map { UInt8($0 &* 7 &+ 3) }) }

    /// Build server-side TLS params from the same PSK (symmetric with the client).
    private func serverParameters(psk: Data) -> NWParameters {
        // Reuse the client's builder — TLS-PSK is symmetric, so the same options
        // serve the listener. The client sets prohibitedInterfaceTypes; harmless on
        // a loopback listener.
        TLSPSK.parameters(psk: psk, identityHint: "loopback-peer")
    }

    func testTLSPSKHandshakeAndCall() throws {
        let key = psk()
        let server = try InProcessNDJSONServer(parameters: serverParameters(psk: key)) { method, _ in
            let r = BridgeWire.DictateStopResult(stopped: method == BridgeWire.Method.dictateStop.rawValue)
            return (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let clientParams = TLSPSK.parameters(psk: key, identityHint: "loopback-peer")
        let conn = NDJSONConnection(host: .init("127.0.0.1"), port: port, parameters: clientParams)
        try conn.start(timeout: 8)   // includes the TLS-PSK handshake
        let session = TCPBridgeSession(connection: conn, callTimeout: 8)
        try session.handshake(clientName: "iPhone tls test")

        let result: BridgeWire.DictateStopResult = try session.call(
            method: BridgeWire.Method.dictateStop.rawValue,
            params: BridgeWire.NoParams(), resultType: BridgeWire.DictateStopResult.self)
        XCTAssertTrue(result.stopped)
        session.close()
    }

    func testMismatchedPSKFailsHandshake() throws {
        let server = try InProcessNDJSONServer(parameters: serverParameters(psk: psk())) { _, _ in
            Data("{\"stopped\":true}".utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        // Client arms a DIFFERENT key → the TLS-PSK handshake must fail to come up.
        let wrongKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let clientParams = TLSPSK.parameters(psk: wrongKey, identityHint: "loopback-peer")
        let conn = NDJSONConnection(host: .init("127.0.0.1"), port: port, parameters: clientParams)
        XCTAssertThrowsError(try conn.start(timeout: 4), "a wrong PSK must not establish TLS") { err in
            // Either a failed handshake or a timeout — both are correct rejections.
            XCTAssertTrue(err is NDJSONConnection.ConnError)
        }
        conn.cancel()
    }
}
