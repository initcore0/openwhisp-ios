import XCTest
import Foundation
import OpenWhispCore
@testable import SyncKit

/// Keychain store CRUD. Uses a per-run unique service namespace so parallel/CI
/// runs never collide, and cleans up after itself.
///
/// The macOS `swift test` host has a login keychain, so these run in the fast
/// gate. If a sandbox ever denies keychain access (errSecMissingEntitlement /
/// errSecInteractionNotAllowed), the first save+read fails cleanly and the test
/// self-skips rather than flapping — the PairingService logic is independently
/// covered against `InMemorySecretStore`.
final class KeychainSecretStoreTests: XCTestCase {
    private var service: String!
    private var store: KeychainSecretStore!

    override func setUp() {
        super.setUp()
        service = "app.openwhisp.ios.sync.test.\(UUID().uuidString)"
        store = KeychainSecretStore(service: service)
    }

    override func tearDown() {
        // Best-effort cleanup of anything left behind.
        store.save("", key: "probe")
        super.tearDown()
    }

    private func requireKeychain() throws {
        store.save("probe-value", key: "probe")
        guard store.read(key: "probe") == "probe-value" else {
            throw XCTSkip("Keychain not writable in this environment; skipping (logic covered via InMemorySecretStore).")
        }
    }

    func testSaveReadUpdateDelete() throws {
        try requireKeychain()
        let key = "k1"
        XCTAssertNil(store.read(key: key))

        store.save("hello", key: key)
        XCTAssertEqual(store.read(key: key), "hello")

        // Update in place.
        store.save("world", key: key)
        XCTAssertEqual(store.read(key: key), "world")

        // Empty = delete (SecretStore contract).
        store.save("", key: key)
        XCTAssertNil(store.read(key: key))
    }

    func testPSKRoundTrip() throws {
        try requireKeychain()
        let peer = UUID()
        let psk = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        XCTAssertNil(store.psk(for: peer))

        store.savePSK(psk, for: peer)
        XCTAssertEqual(store.psk(for: peer), psk)

        store.deletePSK(for: peer)
        XCTAssertNil(store.psk(for: peer))
    }

    func testNamespacesAreIsolated() throws {
        try requireKeychain()
        let other = KeychainSecretStore(service: "app.openwhisp.ios.sync.test.other.\(UUID().uuidString)")
        store.save("mine", key: "shared-key")
        XCTAssertNil(other.read(key: "shared-key"))
        store.save("", key: "shared-key")
    }
}
