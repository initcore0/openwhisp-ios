import XCTest
import Foundation
import Network
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore
@testable import SyncKit

/// The env-gated REAL-Mac loopback tier for the WP7 drive verbs (ARCHITECTURE
/// §8.2). Self-skips unless `OPENWHISP_REMOTE_E2E=1` AND the openwhisp-repo
/// loopback harness (`scripts/sync-loopback-server.sh`) is up: it arms the SAME
/// TLS 1.3 PSK the phone uses, connects to `127.0.0.1:$OPENWHISP_SYNC_PORT`,
/// handshakes, and drives `status` / `dictate` / `refine` / `history.list`
/// through the real ``RemoteMacClient`` over the real `LANBridgeServer`.
///
/// ⚠️ WHAT THIS TIER PROVES — AND WHAT IT CANNOT
///
/// This was RUN against the real harness (openwhisp `mak-51-lan-server`,
/// `scripts/sync-loopback-server.sh`). Findings, verified empirically:
///
/// * The TLS-PSK handshake + `bridge.hello` succeed, and the drive verbs travel
///   the SAME wire the sync engine uses. Proven.
/// * The standalone harness's `LoopbackHost` wires only the REAL SYNC verbs; the
///   drive verbs are stubs (dictate → `internalError`, refine → `llmUnavailable`,
///   history → empty) AND only the `sync` scope is pre-consented, so
///   `dictate`/`refine`/`history.list` come back as a `consentDenied` /
///   `llmUnavailable` domain error — surfaced by the client as a mapped
///   `RemoteMacError`, never a silent failure. So this tier CANNOT prove real
///   captured/refined TEXT — that needs a real paired Mac (see the PR concerns).
/// * The harness's standalone main-thread bridge (`blockOnHost`/`onMain` +
///   `RunLoop.main.run()`) is built for the sync request/response pattern; under
///   the drive tier's rapid open→call→close-per-verb it INTERMITTENTLY drops the
///   connection before flushing the response (observed on `status`/`history`).
///   The client correctly reports that as `RemoteMacError.unreachable`. Because
///   it's a harness timing artifact and not a client defect, this tier asserts
///   the ROBUST invariant — every drive call resolves to a value OR a mapped
///   `RemoteMacError`, never an unmapped throw/crash — rather than pinning an
///   exact server outcome an unreliable harness path can't guarantee.
///
/// Harness contract (identical env to the sync loopback):
///   OPENWHISP_SYNC_PSK   base64 of the 32-byte PSK (both sides)
///   OPENWHISP_SYNC_PORT  TCP port on 127.0.0.1
final class RemoteMacLoopbackE2ETests: XCTestCase {

    private struct Harness { let psk: Data; let port: NWEndpoint.Port }

    private func harnessOrSkip() throws -> Harness {
        guard ProcessInfo.processInfo.environment["OPENWHISP_REMOTE_E2E"] == "1" else {
            throw XCTSkip("OPENWHISP_REMOTE_E2E != 1; remote drive loopback skipped (run scripts/sync-loopback-server.sh in the openwhisp repo).")
        }
        guard let pskB64 = ProcessInfo.processInfo.environment["OPENWHISP_SYNC_PSK"],
              let psk = Data(base64Encoded: pskB64), psk.count == PairingPayload.pskByteCount else {
            throw XCTSkip("OPENWHISP_SYNC_PSK missing/invalid; harness not configured.")
        }
        guard let portStr = ProcessInfo.processInfo.environment["OPENWHISP_SYNC_PORT"],
              let portNum = UInt16(portStr), let port = NWEndpoint.Port(rawValue: portNum) else {
            throw XCTSkip("OPENWHISP_SYNC_PORT missing/invalid; harness not configured.")
        }
        return Harness(psk: psk, port: port)
    }

    private func client(_ h: Harness) -> RemoteMacClient {
        RemoteMacClient(sessionProvider: {
            let params = TLSPSK.parameters(psk: h.psk, identityHint: "remote-e2e")
            let conn = NDJSONConnection(host: .init("127.0.0.1"), port: h.port, parameters: params)
            try conn.start(timeout: 10)
            let session = TCPBridgeSession(connection: conn, callTimeout: 15)
            try session.handshake(clientName: "iPhone remote-e2e")
            return session
        })
    }

    /// Assert the robust invariant: the call resolves to a value OR a mapped
    /// `RemoteMacError`. An unmapped throw (a `SessionError` / raw wire object
    /// leaking) would fail — proving the client's translation layer is total.
    private func assertResolvesOrMapsError<R>(_ body: () throws -> R) {
        do {
            _ = try body()
        } catch let e as RemoteMacError {
            // A mapped, user-facing error — exactly what the UI consumes.
            XCTAssertFalse(e.userMessage.isEmpty, "mapped error had no user message")
        } catch {
            XCTFail("drive call threw an UNMAPPED error over the real wire: \(error)")
        }
    }

    func testStatusOverRealHarness() throws {
        let h = try harnessOrSkip()
        assertResolvesOrMapsError { try self.client(h).remoteStatus() }
    }

    func testHistoryOverRealHarness() throws {
        let h = try harnessOrSkip()
        assertResolvesOrMapsError { try self.client(h).remoteHistory(limit: 10) }
    }

    /// A real Mac would capture on its mic and return the spoken text; the harness
    /// refuses, which the client surfaces as a mapped error.
    func testDictateOverRealHarness() throws {
        let h = try harnessOrSkip()
        assertResolvesOrMapsError { try self.client(h).remoteDictate(prompt: "loopback?") }
    }

    func testRefineOverRealHarness() throws {
        let h = try harnessOrSkip()
        assertResolvesOrMapsError { try self.client(h).remoteRefine(text: "hi", instruction: "shout") }
    }
}
