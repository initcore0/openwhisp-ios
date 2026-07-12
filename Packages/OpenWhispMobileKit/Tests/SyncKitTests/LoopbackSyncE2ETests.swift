import XCTest
import Foundation
import Network
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore
@testable import SyncKit

/// The real-TLS loopback integration tier (ARCHITECTURE §8.2). Self-skips unless
/// `OPENWHISP_SYNC_E2E=1` AND the WP6-mac loopback harness is up. It arms the SAME
/// TLS 1.3 PSK the phone uses, connects to `127.0.0.1:$OPENWHISP_SYNC_PORT`,
/// handshakes, and runs a full `SyncEngine` sync — proving the wire end to end
/// against a real server, not just the in-process fake.
///
/// Harness contract (scripts/sync-loopback-server.sh in the openwhisp repo):
///   env OPENWHISP_SYNC_PSK          — base64 of the 32-byte PSK (both sides)
///       OPENWHISP_SYNC_PORT         — TCP port the server listens on
///       OPENWHISP_SYNC_FIXTURE_DIR  — server's seed vocab/history fixtures
///   prints READY on stdout when accepting connections.
///
/// A dedicated integration agent runs the two together; here we consume the
/// harness via env so this test is a no-op in normal CI.
final class LoopbackSyncE2ETests: XCTestCase {

    private struct HarnessConfig {
        let psk: Data
        let port: NWEndpoint.Port
    }

    private func harnessOrSkip() throws -> HarnessConfig {
        guard ProcessInfo.processInfo.environment["OPENWHISP_SYNC_E2E"] == "1" else {
            throw XCTSkip("OPENWHISP_SYNC_E2E != 1; loopback harness test skipped (run scripts/sync-loopback-server.sh).")
        }
        guard let pskB64 = ProcessInfo.processInfo.environment["OPENWHISP_SYNC_PSK"],
              let psk = Data(base64Encoded: pskB64), psk.count == PairingPayload.pskByteCount else {
            throw XCTSkip("OPENWHISP_SYNC_PSK missing/invalid; harness not configured.")
        }
        guard let portStr = ProcessInfo.processInfo.environment["OPENWHISP_SYNC_PORT"],
              let portNum = UInt16(portStr), let port = NWEndpoint.Port(rawValue: portNum) else {
            throw XCTSkip("OPENWHISP_SYNC_PORT missing/invalid; harness not configured.")
        }
        return HarnessConfig(psk: psk, port: port)
    }

    /// Connect to the loopback harness over TLS-PSK and return a handshaked session.
    private func connect(_ config: HarnessConfig) throws -> TCPBridgeSession {
        let params = TLSPSK.parameters(psk: config.psk, identityHint: "loopback-peer")
        let conn = NDJSONConnection(host: .init("127.0.0.1"), port: config.port, parameters: params)
        try conn.start(timeout: 10)
        let session = TCPBridgeSession(connection: conn, callTimeout: 15)
        try session.handshake(clientName: "iPhone loopback E2E")
        return session
    }

    func testFullSyncOverRealTLS() throws {
        let config = try harnessOrSkip()

        // Phone-side store seeded with a unique substitution + history entry so we
        // can assert the two-way merge crosses the real wire.
        let phoneSubID = UUID()
        let phoneEntry = TranscriptionEntry(
            text: "phone-\(UUID().uuidString)", date: Date(),
            appBundleID: "app.openwhisp.ios", appName: "OpenWhisp")
        let store = InMemorySyncStore(
            vocabulary: Vocabulary(terms: ["iphone-term"], substitutions: [
                Vocabulary.Substitution(id: phoneSubID, from: "fone", to: "phone", updatedAt: Date())]),
            history: [phoneEntry])

        let engine = SyncEngine(store: store)

        // First sync: pull the Mac's fixtures + push ours.
        let session = try connect(config)
        let report = try engine.run(with: session)
        session.close()
        XCTAssertTrue(report.didAnything, "first sync should move data both ways")
        // We pushed our unique entry; the harness echoes merged counts.
        XCTAssertGreaterThanOrEqual(report.pushed.vocabulary + report.pushed.history, 1)

        // Second sync on a fresh connection must be a clean no-op (idempotency).
        let session2 = try connect(config)
        let report2 = try engine.run(with: session2)
        session2.close()
        XCTAssertFalse(report2.didAnything, "second sync must be idempotent (no-op)")
    }
}
