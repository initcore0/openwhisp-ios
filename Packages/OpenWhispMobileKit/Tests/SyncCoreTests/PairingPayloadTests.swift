import XCTest
import Foundation
@testable import SyncCore

/// QR payload parse: valid, garbage, future-version, bad PSK/UUID.
final class PairingPayloadTests: XCTestCase {

    private func psk32() -> Data { Data((0..<32).map { UInt8($0) }) }

    private func qr(
        version: Int = 1, peerID: String = UUID().uuidString,
        displayName: String = "Max's MacBook Pro",
        pskBase64: String? = nil, serviceKey: String = "serviceInstance",
        serviceValue: String = "OpenWhisp-abc123"
    ) -> Data {
        let pskB64 = pskBase64 ?? psk32().base64EncodedString()
        let json: [String: Any] = [
            "version": version, "peerID": peerID, "displayName": displayName,
            "psk": pskB64, serviceKey: serviceValue,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testValidPayloadParses() throws {
        let p = try PairingPayload.parse(qr())
        XCTAssertEqual(p.version, 1)
        XCTAssertEqual(p.displayName, "Max's MacBook Pro")
        XCTAssertEqual(p.psk.count, 32)
        XCTAssertEqual(p.serviceInstance, "OpenWhisp-abc123")
        XCTAssertFalse(p.pskFingerprint.isEmpty)
    }

    func testFingerprintIsDeterministicAndNotThePSK() {
        let fp1 = PairingPayload.fingerprint(forPSK: psk32())
        let fp2 = PairingPayload.fingerprint(forPSK: psk32())
        XCTAssertEqual(fp1, fp2)
        XCTAssertFalse(fp1.contains(psk32().base64EncodedString()))
        // 8 bytes -> 8 hex pairs joined by spaces
        XCTAssertEqual(fp1.split(separator: " ").count, 8)
    }

    func testPeerIdentityExcludesPSK() throws {
        let p = try PairingPayload.parse(qr())
        let identity = p.peerIdentity()
        XCTAssertEqual(identity.id, p.peerID)
        XCTAssertEqual(identity.pskFingerprint, p.pskFingerprint)
        // Round-trip the identity through JSON and confirm no raw PSK leaked in.
        let data = try JSONEncoder().encode(identity)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertFalse(str.contains(p.psk.base64EncodedString()))
    }

    func testGarbageThrowsMalformed() {
        XCTAssertThrowsError(try PairingPayload.parse(Data("not json".utf8))) { err in
            guard case PairingPayload.ParseError.malformed = err else {
                return XCTFail("expected .malformed, got \(err)")
            }
        }
    }

    func testFutureVersionRejected() {
        XCTAssertThrowsError(try PairingPayload.parse(qr(version: 2))) { err in
            guard case PairingPayload.ParseError.unsupportedVersion(let found, let supported) = err else {
                return XCTFail("expected .unsupportedVersion, got \(err)")
            }
            XCTAssertEqual(found, 2)
            XCTAssertEqual(supported, 1)
        }
    }

    func testZeroVersionRejected() {
        XCTAssertThrowsError(try PairingPayload.parse(qr(version: 0)))
    }

    func testBadPSKNotBase64() {
        XCTAssertThrowsError(try PairingPayload.parse(qr(pskBase64: "!!!not base64!!!"))) { err in
            guard case PairingPayload.ParseError.invalidPSK = err else {
                return XCTFail("expected .invalidPSK, got \(err)")
            }
        }
    }

    func testWrongLengthPSKRejected() {
        let short = Data((0..<16).map { UInt8($0) }).base64EncodedString()
        XCTAssertThrowsError(try PairingPayload.parse(qr(pskBase64: short))) { err in
            guard case PairingPayload.ParseError.invalidPSK = err else {
                return XCTFail("expected .invalidPSK, got \(err)")
            }
        }
    }

    func testBadUUIDRejected() {
        XCTAssertThrowsError(try PairingPayload.parse(qr(peerID: "not-a-uuid"))) { err in
            guard case PairingPayload.ParseError.invalidPeerID = err else {
                return XCTFail("expected .invalidPeerID, got \(err)")
            }
        }
    }

    func testServiceInstanceAliasesAccepted() throws {
        let p1 = try PairingPayload.parse(qr(serviceKey: "service", serviceValue: "Svc-1"))
        XCTAssertEqual(p1.serviceInstance, "Svc-1")
        let p2 = try PairingPayload.parse(qr(serviceKey: "service_instance", serviceValue: "Svc-2"))
        XCTAssertEqual(p2.serviceInstance, "Svc-2")
    }
}
