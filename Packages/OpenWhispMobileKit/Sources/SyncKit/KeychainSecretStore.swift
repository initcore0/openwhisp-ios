import Foundation
import Security
import OpenWhispCore

/// The iOS/macOS Keychain conformer of upstream ``SecretStore`` (ARCHITECTURE
/// §6.5 / §7). Holds the 32-byte pairing PSK per peer, keyed by the peer UUID.
///
/// Contract inherited from ``SecretStore``: `save` with an empty string DELETES
/// the item; `read` returns nil when absent. We store the PSK as base64 text so
/// the string-typed protocol carries the raw bytes losslessly (convenience
/// accessors below hand callers `Data`).
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: available to the
/// foreground-only sync after the user first unlocks post-boot, and never
/// migrated off the device by an iCloud/iTunes backup — the key is meaningless on
/// any other device and must not travel.
public final class KeychainSecretStore: SecretStore {
    private let service: String

    /// - Parameter service: the Keychain `kSecAttrService` namespace. Defaults to
    ///   the app's sync namespace; tests pass a unique value so runs don't collide.
    public init(service: String = "app.openwhisp.ios.sync") {
        self.service = service
    }

    public func read(key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ value: String, key: String) {
        // Empty string = delete (SecretStore contract).
        guard !value.isEmpty else { delete(key: key); return }
        let data = Data(value.utf8)

        // Try update-in-place first; if the item doesn't exist, add it.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(key) as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func delete(key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    // MARK: - PSK convenience (raw bytes ⇄ base64 string)

    /// Keychain account key for a peer's PSK.
    public static func pskKey(for peer: UUID) -> String { "psk.\(peer.uuidString)" }

    /// Store a raw PSK for `peer` (base64-encoded under the hood).
    public func savePSK(_ psk: Data, for peer: UUID) {
        save(psk.base64EncodedString(), key: Self.pskKey(for: peer))
    }

    /// Read the raw PSK for `peer`, or nil if this device isn't paired to it.
    public func psk(for peer: UUID) -> Data? {
        guard let b64 = read(key: Self.pskKey(for: peer)) else { return nil }
        return Data(base64Encoded: b64)
    }

    /// Destroy a peer's PSK (unpair = key destruction).
    public func deletePSK(for peer: UUID) {
        delete(key: Self.pskKey(for: peer))
    }
}
