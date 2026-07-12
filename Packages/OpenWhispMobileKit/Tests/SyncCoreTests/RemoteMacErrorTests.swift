import XCTest
import OpenWhispCore
@testable import SyncCore

/// The pure WP7 mapping gate: EVERY `BridgeWire.ErrorCode` maps to a defined
/// `RemoteMacError`, the `ErrorObject` path threads `retryAfterSeconds`/
/// `originalText`, and an unknown (nil) code falls through to the Mac's own
/// message. No device, no network — the OS-bound `RemoteMacClient` stays thin
/// because this decision table is proven here.
final class RemoteMacErrorTests: XCTestCase {

    /// Exhaustive: iterate the CaseIterable error codes so a NEW wire error code
    /// added upstream fails this test until it's mapped (no silent `default`).
    func testEveryBridgeErrorCodeMapsToADefinedCase() {
        for code in BridgeWire.ErrorCode.allCases {
            let mapped = RemoteMacError.from(bridgeCode: code, message: "msg for \(code.rawValue)")
            // Every mapping must produce a non-empty user sentence.
            XCTAssertFalse(mapped.userMessage.isEmpty, "empty message for \(code.rawValue)")

            switch code {
            case .busy:                XCTAssertEqual(mapped, .macBusy)
            case .rateLimited:         XCTAssertEqual(mapped, .rateLimited(retryAfterSeconds: nil))
            case .consentDenied:       XCTAssertEqual(mapped, .consentDenied)
            case .cancelled:           XCTAssertEqual(mapped, .dictationCancelled)
            case .timeout:             XCTAssertEqual(mapped, .dictationTimedOut)
            case .micPermissionNeeded: XCTAssertEqual(mapped, .micPermissionNeeded)
            case .secureField:         XCTAssertEqual(mapped, .secureField)
            case .llmUnavailable:      XCTAssertEqual(mapped, .llmUnavailable(originalText: nil))
            case .cloudRefineDisabled: XCTAssertEqual(mapped, .cloudRefineDisabled)
            case .historyDisabled:     XCTAssertEqual(mapped, .historyDisabled)
            case .unsupportedVersion:  XCTAssertEqual(mapped, .unsupportedVersion)
            case .audioUnavailable:
                if case .unreachable = mapped {} else { XCTFail("audioUnavailable should map to .unreachable") }
            case .unsupportedFormat, .malformedRequest, .unknownMethod, .internalError:
                XCTAssertEqual(mapped, .macError(message: "msg for \(code.rawValue)"))
            }
        }
    }

    func testRateLimitedCarriesRetryAfter() {
        let mapped = RemoteMacError.from(
            bridgeCode: .rateLimited, message: "slow down", retryAfterSeconds: 12)
        XCTAssertEqual(mapped, .rateLimited(retryAfterSeconds: 12))
        XCTAssertTrue(mapped.userMessage.contains("12s"), "retry-after not surfaced: \(mapped.userMessage)")
    }

    func testRateLimitedWithoutRetryAfterStillReadable() {
        let mapped = RemoteMacError.from(bridgeCode: .rateLimited, message: "slow down")
        XCTAssertEqual(mapped, .rateLimited(retryAfterSeconds: nil))
        XCTAssertFalse(mapped.userMessage.isEmpty)
    }

    func testLLMUnavailableCarriesOriginalText() {
        let mapped = RemoteMacError.from(
            bridgeCode: .llmUnavailable, message: "no model", originalText: "keep me")
        XCTAssertEqual(mapped, .llmUnavailable(originalText: "keep me"))
    }

    /// A `reason` a newer Mac introduces that this build can't decode arrives as
    /// nil (ErrorData's tolerant decode) — the Mac's own message must still show.
    func testUnknownReasonFallsThroughToMacMessage() {
        let mapped = RemoteMacError.from(bridgeCode: nil, message: "some new failure")
        XCTAssertEqual(mapped, .macError(message: "some new failure"))
        XCTAssertEqual(mapped.userMessage, "some new failure")
    }

    /// The ErrorObject overload pulls reason + data fields straight off the wire
    /// object (the shape `TCPBridgeSession` decodes on a domain error).
    func testFromErrorObjectThreadsDataFields() {
        let obj = BridgeWire.ErrorObject.domain(
            .rateLimited, message: "throttled", retryAfterSeconds: 7)
        XCTAssertEqual(RemoteMacError.from(bridgeError: obj), .rateLimited(retryAfterSeconds: 7))

        let refineFail = BridgeWire.ErrorObject.domain(
            .llmUnavailable, message: "down", originalText: "orig")
        XCTAssertEqual(RemoteMacError.from(bridgeError: refineFail), .llmUnavailable(originalText: "orig"))
    }

    func testMacBusyMessageDistinctFromRateLimited() {
        XCTAssertNotEqual(RemoteMacError.macBusy.userMessage,
                          RemoteMacError.rateLimited(retryAfterSeconds: nil).userMessage)
    }
}
