import XCTest
import Foundation
import OpenWhispCore
import SyncCore
@testable import SyncKit

/// PairingService against an in-memory secret store + a tempdir peer store (no
/// Keychain, no network). Covers pair → stored PSK + peer, unpair → key
/// destruction, and rejection of a bad QR.
final class PairingServiceTests: XCTestCase {
    private var tempDir: URL!
    private var secrets: InMemorySecretStore!
    private var service: DefaultPairingService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        secrets = InMemorySecretStore()
        let peerStore = PeerStore(fileURL: tempDir.appendingPathComponent("peers.json"))
        service = DefaultPairingService(secrets: secrets, peerStore: peerStore)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func qrData(peerID: UUID = UUID(), psk: Data? = nil) -> (Data, Data) {
        let pskData = psk ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let json: [String: Any] = [
            "version": 1, "peerID": peerID.uuidString, "displayName": "Test Mac",
            "psk": pskData.base64EncodedString(), "serviceInstance": "OpenWhisp-test",
        ]
        return (try! JSONSerialization.data(withJSONObject: json), pskData)
    }

    func testCompletePairingStoresPSKAndPeer() throws {
        let (qr, psk) = qrData()
        let peer = try service.completePairing(scannedQR: qr)

        XCTAssertEqual(service.pairedPeers.count, 1)
        XCTAssertEqual(service.pairedPeers.first?.id, peer.id)
        // The PSK is retrievable and matches; the peer record carries only the fingerprint.
        XCTAssertEqual(service.psk(for: peer.id), psk)
        XCTAssertEqual(peer.pskFingerprint, PairingPayload.fingerprint(forPSK: psk))
        XCTAssertEqual(peer.serviceInstance, "OpenWhisp-test")
    }

    func testUnpairDestroysKey() throws {
        let (qr, _) = qrData()
        let peer = try service.completePairing(scannedQR: qr)
        XCTAssertNotNil(service.psk(for: peer.id))

        try service.unpair(peer.id)
        XCTAssertNil(service.psk(for: peer.id), "PSK must be destroyed on unpair")
        XCTAssertTrue(service.pairedPeers.isEmpty)
    }

    func testRePairRefreshesRecord() throws {
        let peerID = UUID()
        let (qr1, _) = qrData(peerID: peerID)
        _ = try service.completePairing(scannedQR: qr1)
        let (qr2, psk2) = qrData(peerID: peerID)
        _ = try service.completePairing(scannedQR: qr2)

        XCTAssertEqual(service.pairedPeers.count, 1, "same peer id must not duplicate")
        XCTAssertEqual(service.psk(for: peerID), psk2, "re-pair updates the stored key")
    }

    func testGarbageQRRejectedAndNothingStored() {
        XCTAssertThrowsError(try service.completePairing(scannedQR: Data("garbage".utf8)))
        XCTAssertTrue(service.pairedPeers.isEmpty)
    }

    func testPeerStorePersistsAcrossInstances() throws {
        let (qr, _) = qrData()
        _ = try service.completePairing(scannedQR: qr)
        // A fresh service over the same files sees the paired peer.
        let peerStore = PeerStore(fileURL: tempDir.appendingPathComponent("peers.json"))
        let reopened = DefaultPairingService(secrets: secrets, peerStore: peerStore)
        XCTAssertEqual(reopened.pairedPeers.count, 1)
    }
}
