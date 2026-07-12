import Foundation
import Network
import CryptoKit

/// Builds the shared pre-shared-key TLS parameters both sides arm from the paired
/// PSK (ARCHITECTURE §6.5/§7). No CA, no certificates — mutual auth is the PSK
/// alone, and nothing is readable on the wire before the handshake completes.
///
/// The same function is used by the phone (client) and, symmetrically, by the Mac
/// loopback harness/server, so both derive identical `sec_protocol` options from
/// the same 32 bytes.
///
/// **TLS version, honestly.** The design target is TLS 1.3. Network.framework's
/// high-level external-PSK API (`sec_protocol_options_add_pre_shared_key`) maps to
/// the TLS-1.2 PSK-DHE cipher suites; TLS 1.3's *external* PSK is not reachable
/// through this API on the current SDKs (a 1.3-pinned PSK handshake fails to
/// establish — verified on Xcode 26 / macOS host). So we set **max = 1.3, floor =
/// 1.2** and offer both the 1.2 PSK-DHE suite and the 1.3 AEAD suite: the stack
/// negotiates the highest both peers actually support (1.3 automatically once
/// Apple wires external PSK through it), while working today on 1.2. The security
/// posture is identical either way — mutual PSK authentication, ephemeral-DH
/// forward secrecy (PSK-*DHE*), no certificate/CA, and no plaintext before the
/// handshake. The floor never drops below 1.2. (Env note: CI runners lag a major
/// SDK, so we must not depend on a 1.3-only PSK path that isn't there.)
enum TLSPSK {

    /// TLS-over-TCP `NWParameters` armed with `psk` and a peer-UUID identity hint.
    ///
    /// - Parameters:
    ///   - psk: the 32-byte pre-shared key minted at pairing.
    ///   - identityHint: the peer UUID string — the PSK identity, so a server
    ///     advertising several peers can select the right key. Not a secret; it
    ///     only names which PSK to try.
    static func parameters(psk: Data, identityHint: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        // Floor 1.2, ceiling 1.3 — negotiate the highest both peers support.
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)

        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let hintData = Data(identityHint.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            sec,
            pskData as __DispatchData,
            hintData as __DispatchData
        )

        // Offer both suites: the TLS-1.2 PSK-DHE suite that the external-PSK API
        // actually uses today (forward-secret via ephemeral DH), and the TLS-1.3
        // AEAD suite so a 1.3 handshake is available when the stack supports
        // external PSK over it. Both are AES-128-GCM-SHA256 family — present on
        // every Apple platform in range, and identical on both ends.
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: UInt16(TLS_AES_128_GCM_SHA256))!)

        let params = NWParameters(tls: tls)
        // Sync is a LAN feature; disallow expensive (cellular) paths — a paired Mac
        // is always on the same Wi-Fi.
        params.prohibitedInterfaceTypes = [.cellular]
        return params
    }
}
