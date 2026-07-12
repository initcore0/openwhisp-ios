import Foundation
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore
import SyncKit

/// DEBUG-only test seams that let the host-app XCUITest land on a deterministic
/// paired + drivable "Your Mac" surface WITHOUT a real Mac, camera, or network.
///
/// Two launch arguments:
///   `-uitest-remote-paired`  — seed one fake paired peer so the paired card +
///                              the WP7 drive controls render.
///   `-uitest-remote-stub`    — back the ``RemoteMacCoordinator`` with an
///                              in-process stub session, so tapping a drive
///                              control returns canned text (never touches the
///                              LAN). Implies `-uitest-remote-paired`.
///
/// Kept out of the shipping build (`#if DEBUG`) — production always uses the real
/// Keychain pairing + Bonjour/TLS transport.
#if DEBUG
enum RemoteMacUITestSupport {
    static var wantsPaired: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-uitest-remote-paired") || args.contains("-uitest-remote-stub")
    }

    static var wantsStub: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-remote-stub")
    }

    static let fakePeer = PeerIdentity(
        id: UUID(uuidString: "0BADF00D-0000-0000-0000-00000000CAFE")!,
        displayName: "Test Mac",
        pskFingerprint: "AB CD EF 01",
        serviceInstance: "OpenWhisp-uitest",
        lastSeen: nil)

    /// A `PairingService` that reports one paired peer and a dummy PSK, so the
    /// coordinators believe a Mac is paired.
    static func makePairingService() -> PairingService {
        FakePairingService(peer: fakePeer)
    }

    /// A `RemoteMacClient` whose session is an in-process stub returning canned
    /// results — the drive controls produce visible output on the simulator.
    static func makeStubClient(for _: PeerIdentity) -> RemoteMacClient {
        RemoteMacClient(sessionProvider: { StubDriveSession() })
    }
}

/// A paired-service stub for the UITest surface.
private final class FakePairingService: PairingService {
    private let peer: PeerIdentity
    init(peer: PeerIdentity) { self.peer = peer }
    func completePairing(scannedQR: Data) throws -> PeerIdentity { peer }
    func unpair(_ peer: PeerIdentity.ID) throws {}
    var pairedPeers: [PeerIdentity] { [peer] }
    func psk(for peer: PeerIdentity.ID) -> Data? { Data(count: 32) }
}

/// A canned in-process `BridgeSession` for the UITest drive surface: dictate
/// returns a fixed sentence, refine echoes an upper-cased instruction, history
/// returns two rows, status is a plausible snapshot.
private final class StubDriveSession: BridgeSession {
    func handshake(clientName: String) throws {}

    func call<P, R>(method: String, params: P?, resultType: R.Type) throws -> R
        where P: Codable & Sendable, R: Decodable
    {
        let result: Any
        switch method {
        case BridgeWire.Method.status.rawValue:
            result = BridgeWire.StatusResult(
                appVersion: "uitest", engine: "parakeet", model: "v3", sessionActive: false,
                llmConfigured: true, llmProvider: "local", sendsTextToCloud: false, historyEnabled: true)
        case BridgeWire.Method.dictate.rawValue:
            result = BridgeWire.DictateResult(
                text: "Heard you loud and clear.", durationSeconds: 1.0, timedOut: false, endedBy: .user)
        case BridgeWire.Method.dictateStop.rawValue:
            result = BridgeWire.DictateStopResult(stopped: true)
        case BridgeWire.Method.refine.rawValue:
            result = BridgeWire.RefineResult(text: "Refined by your Mac.")
        case BridgeWire.Method.historyList.rawValue:
            result = BridgeWire.HistoryListResult(entries: [
                BridgeWire.HistoryEntryDTO(
                    id: UUID(), text: "First remembered note",
                    date: BridgeWire.iso8601String(from: Date()),
                    appBundleID: "com.apple.Notes", appName: "Notes", initiator: "user"),
                BridgeWire.HistoryEntryDTO(
                    id: UUID(), text: "An agent-made note",
                    date: BridgeWire.iso8601String(from: Date().addingTimeInterval(-60)),
                    appBundleID: nil, appName: "Mail", initiator: "agent"),
            ])
        default:
            throw TCPBridgeSession.SessionError.domain(reason: .unknownMethod, message: "stub: \(method)", data: nil)
        }
        guard let typed = result as? R else {
            throw TCPBridgeSession.SessionError.undecodable("stub had no result for \(method)")
        }
        return typed
    }
}
#endif
