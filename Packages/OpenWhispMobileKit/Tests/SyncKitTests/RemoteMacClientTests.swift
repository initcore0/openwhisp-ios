import XCTest
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore
@testable import SyncKit

/// Drives ``RemoteMacClient`` against the in-process ``FakeBridgeSession`` — every
/// verb round-trips (params in, typed result out) and every bridge refusal
/// surfaces as the right ``RemoteMacError``. No network, no Mac.
final class RemoteMacClientTests: XCTestCase {

    private func client(_ session: FakeBridgeSession) -> RemoteMacClient {
        RemoteMacClient(sessionProvider: { session })
    }

    private func status() -> BridgeWire.StatusResult {
        BridgeWire.StatusResult(
            appVersion: "1.0", engine: "parakeet", model: "v3", sessionActive: false,
            llmConfigured: true, llmProvider: "local", sendsTextToCloud: false, historyEnabled: true)
    }

    // MARK: Happy-path round-trips

    func testStatusRoundTrips() throws {
        let s = FakeBridgeSession(); s.status = status()
        let result = try client(s).remoteStatus()
        XCTAssertEqual(result.engine, "parakeet")
        XCTAssertEqual(s.calls, [BridgeWire.Method.status.rawValue])
    }

    func testDictateRoundTripsAndForwardsParams() throws {
        let s = FakeBridgeSession()
        s.dictateResult = BridgeWire.DictateResult(
            text: "hello from the mac", durationSeconds: 2.5, timedOut: false, endedBy: .user)
        let result = try client(s).remoteDictate(prompt: "What's the ETA?", timeoutSeconds: 45, language: "en")
        XCTAssertEqual(result.text, "hello from the mac")
        XCTAssertEqual(result.endedBy, .user)
        // Params reached the wire intact — this IS the answer-a-question path.
        XCTAssertEqual(s.lastDictateParams?.prompt, "What's the ETA?")
        XCTAssertEqual(s.lastDictateParams?.timeoutSeconds, 45)
        XCTAssertEqual(s.lastDictateParams?.language, "en")
    }

    func testStopRoundTrips() throws {
        let s = FakeBridgeSession(); s.stopResult = BridgeWire.DictateStopResult(stopped: true)
        XCTAssertTrue(try client(s).remoteStopDictation().stopped)
        XCTAssertEqual(s.calls, [BridgeWire.Method.dictateStop.rawValue])
    }

    func testRefineRoundTripsAndForwardsParams() throws {
        let s = FakeBridgeSession()
        s.refineResult = BridgeWire.RefineResult(text: "Refined text.")
        let result = try client(s).remoteRefine(text: "raw text", instruction: "make it formal")
        XCTAssertEqual(result.text, "Refined text.")
        XCTAssertEqual(s.lastRefineParams?.text, "raw text")
        XCTAssertEqual(s.lastRefineParams?.instruction, "make it formal")
    }

    func testHistoryRoundTripsAndMapsToDisplayRows() throws {
        let s = FakeBridgeSession()
        let id = UUID()
        s.historyResult = BridgeWire.HistoryListResult(entries: [
            BridgeWire.HistoryEntryDTO(
                id: id, text: "first note", date: BridgeWire.iso8601String(from: Date()),
                appBundleID: "com.apple.Notes", appName: "Notes", initiator: "user"),
        ])
        let rows = try client(s).remoteHistory(limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, id)
        XCTAssertEqual(rows[0].appLabel, "Notes")
        XCTAssertEqual(rows[0].initiator, .user)
        XCTAssertNotNil(rows[0].date)
        XCTAssertEqual(s.lastHistoryParams?.limit, 10)
    }

    func testEmptyHistoryRoundTrips() throws {
        let s = FakeBridgeSession(); s.historyResult = BridgeWire.HistoryListResult(entries: [])
        XCTAssertTrue(try client(s).remoteHistory().isEmpty)
    }

    // MARK: Error surfacing

    func testConsentDeniedSurfaces() {
        let s = FakeBridgeSession()
        s.domainErrors[BridgeWire.Method.dictate.rawValue] = (.consentDenied, "user declined")
        XCTAssertThrowsError(try client(s).remoteDictate(prompt: "hi")) { error in
            XCTAssertEqual(error as? RemoteMacError, .consentDenied)
        }
    }

    func testBusySurfaces() {
        let s = FakeBridgeSession()
        s.domainErrors[BridgeWire.Method.dictate.rawValue] = (.busy, "already dictating")
        XCTAssertThrowsError(try client(s).remoteDictate()) { error in
            XCTAssertEqual(error as? RemoteMacError, .macBusy)
        }
    }

    func testRateLimitedSurfaces() {
        let s = FakeBridgeSession()
        s.domainErrors[BridgeWire.Method.dictate.rawValue] = (.rateLimited, "throttled")
        XCTAssertThrowsError(try client(s).remoteDictate()) { error in
            // retryAfter is not carried by the fake's simple domain path; nil is fine.
            XCTAssertEqual(error as? RemoteMacError, .rateLimited(retryAfterSeconds: nil))
        }
    }

    func testLLMUnavailableSurfacesOnRefine() {
        let s = FakeBridgeSession()
        s.domainErrors[BridgeWire.Method.refine.rawValue] = (.llmUnavailable, "no model")
        XCTAssertThrowsError(try client(s).remoteRefine(text: "x", instruction: "y")) { error in
            XCTAssertEqual(error as? RemoteMacError, .llmUnavailable(originalText: nil))
        }
    }

    func testHistoryDisabledSurfaces() {
        let s = FakeBridgeSession()
        s.domainErrors[BridgeWire.Method.historyList.rawValue] = (.historyDisabled, "off")
        XCTAssertThrowsError(try client(s).remoteHistory()) { error in
            XCTAssertEqual(error as? RemoteMacError, .historyDisabled)
        }
    }

    func testSecureFieldSurfacesOnDictate() {
        let s = FakeBridgeSession()
        s.domainErrors[BridgeWire.Method.dictate.rawValue] = (.secureField, "password field focused")
        XCTAssertThrowsError(try client(s).remoteDictate()) { error in
            XCTAssertEqual(error as? RemoteMacError, .secureField)
        }
    }

    // MARK: Session-open failures

    func testSessionOpenFailureSurfacesAsUnreachable() {
        let client = RemoteMacClient(sessionProvider: {
            throw BonjourPeerTransport.TransportError.peerNotFound("Max's Mac")
        })
        XCTAssertThrowsError(try client.remoteStatus()) { error in
            guard case .unreachable = (error as? RemoteMacError) else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        }
    }

    func testNotPairedSurfaces() {
        let client = RemoteMacClient(sessionProvider: { throw RemoteMacError.notPaired })
        XCTAssertThrowsError(try client.remoteStatus()) { error in
            XCTAssertEqual(error as? RemoteMacError, .notPaired)
        }
    }

    func testUnsupportedVersionSurfaces() {
        let s = FakeBridgeSession()
        s.domainErrors[BridgeWire.Method.status.rawValue] = (nil, "old")
        // A nil reason with the unsupportedVersion SessionError path is separate;
        // here nil reason → macError. Verify the dedicated version error instead:
        let client = RemoteMacClient(sessionProvider: {
            throw TCPBridgeSession.SessionError.unsupportedVersion
        })
        XCTAssertThrowsError(try client.remoteStatus()) { error in
            XCTAssertEqual(error as? RemoteMacError, .unsupportedVersion)
        }
        _ = s
    }
}
