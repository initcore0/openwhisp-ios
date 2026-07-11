import Foundation

// MARK: - SyncKit (placeholder — WP6)
//
// The Network.framework transports and the P2P sync engine. This target is a
// placeholder in WP1 (the scaffold): it holds only this doc comment so the
// target compiles and the module boundary exists. No feature code lands until
// WP6.
//
// When WP6 arrives, SyncKit will own (interfaces per ARCHITECTURE §6.5–6.6):
//
//   - `PeerIdentity`, `PairingService`         — QR out-of-band pairing, PSK in
//                                                Keychain (via upstream SecretStore).
//   - `BonjourPeerTransport: PeerTransport`     — NWBrowser discovery + NWConnection
//                                                TLS-PSK, returning an upstream
//                                                `BridgeSession` conformer.
//   - `SyncEngine`                             — pure `plan(local:remote:)` merge
//                                                (fully tested) + `run(with:)` over
//                                                the paired BridgeSession.
//   - MCP client plumbing driving the Mac hub's dictate/refine/history verbs.
//
// The sync wire IS the Agent Bridge (NDJSON JSON-RPC) over TLS/TCP instead of a
// UNIX socket, so it reuses upstream `BridgeWire`/`BridgeRouter`/`AgentClientStore`
// verbatim — which is exactly why those types come from the OpenWhispCore
// dependency (added with the engine/sync work), not WP1.

/// Marker so the module is non-empty and its presence is greppable. Removed when
/// real types land in WP6.
enum SyncKitPlaceholder {}
