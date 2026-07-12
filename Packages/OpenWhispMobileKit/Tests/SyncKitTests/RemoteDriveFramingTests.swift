import XCTest
import Foundation
import Network
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore
@testable import SyncKit

/// Proves the WP7 drive verbs round-trip over the REAL NDJSON framing +
/// handshake of ``TCPBridgeSession`` — a loopback `NWConnection`, no TLS, no Mac —
/// driven through ``RemoteMacClient``. The in-process server can only return
/// `result` envelopes (not errors), so this tier proves the SUCCESS wire path;
/// error surfacing is covered against the fake in ``RemoteMacClientTests``.
final class RemoteDriveFramingTests: XCTestCase {

    /// A RemoteMacClient whose session is a real TCPBridgeSession over loopback to
    /// the given in-process server.
    private func client(port: NWEndpoint.Port) -> RemoteMacClient {
        RemoteMacClient(sessionProvider: {
            let params = NWParameters.tcp
            params.prohibitedInterfaceTypes = [.cellular]
            let conn = NDJSONConnection(host: .init("127.0.0.1"), port: port, parameters: params)
            try conn.start(timeout: 5)
            let session = TCPBridgeSession(connection: conn, callTimeout: 5)
            try session.handshake(clientName: "iPhone drive test")
            return session
        })
    }

    func testDictateRoundTripsOverRealFraming() throws {
        let server = try InProcessNDJSONServer { method, _ in
            XCTAssertEqual(method, BridgeWire.Method.dictate.rawValue)
            let r = BridgeWire.DictateResult(
                text: "spoken answer", durationSeconds: 1.2, timedOut: false, endedBy: .user)
            return (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let result = try client(port: port).remoteDictate(prompt: "Ship it?", timeoutSeconds: 30)
        XCTAssertEqual(result.text, "spoken answer")
        XCTAssertEqual(result.endedBy, .user)
    }

    func testRefineRoundTripsOverRealFraming() throws {
        let server = try InProcessNDJSONServer { method, paramsJSON in
            XCTAssertEqual(method, BridgeWire.Method.refine.rawValue)
            // Echo the instruction back in the refined text to prove params arrived.
            let params = try? JSONDecoder().decode(BridgeWire.RefineParams.self, from: paramsJSON)
            let r = BridgeWire.RefineResult(text: "[\(params?.instruction ?? "?")] \(params?.text ?? "")")
            return (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let result = try client(port: port).remoteRefine(text: "hello", instruction: "shout")
        XCTAssertEqual(result.text, "[shout] hello")
    }

    func testHistoryRoundTripsOverRealFraming() throws {
        let id = UUID()
        let server = try InProcessNDJSONServer { method, _ in
            XCTAssertEqual(method, BridgeWire.Method.historyList.rawValue)
            let r = BridgeWire.HistoryListResult(entries: [
                BridgeWire.HistoryEntryDTO(
                    id: id, text: "note", date: BridgeWire.iso8601String(from: Date()),
                    appBundleID: nil, appName: "Mail", initiator: "agent"),
            ])
            return (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let rows = try client(port: port).remoteHistory(limit: 5)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, id)
        XCTAssertEqual(rows[0].appLabel, "Mail")
        XCTAssertEqual(rows[0].initiator, .agent)
    }

    func testStatusRoundTripsOverRealFraming() throws {
        let server = try InProcessNDJSONServer { method, _ in
            XCTAssertEqual(method, BridgeWire.Method.status.rawValue)
            let r = BridgeWire.StatusResult(
                appVersion: "9.9", engine: "parakeet", model: "v3", sessionActive: true,
                llmConfigured: true, llmProvider: "local", sendsTextToCloud: false, historyEnabled: true)
            return (try? JSONEncoder().encode(r)) ?? Data("{}".utf8)
        }
        let port = try server.start()
        defer { server.stop() }

        let result = try client(port: port).remoteStatus()
        XCTAssertEqual(result.appVersion, "9.9")
        XCTAssertTrue(result.sessionActive)
    }
}
