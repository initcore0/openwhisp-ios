import Foundation
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore

/// Drives a paired Mac's Agent Bridge tools — `dictate` / `dictate.stop` /
/// `refine` / `history.list` / `status` — over the SAME TLS-PSK `BridgeSession`
/// the sync engine uses (WP7, ARCHITECTURE §6.6). The phone is "one more agent
/// client": every call lands on the Mac's existing consent + rate-limit path, so
/// this client builds NOTHING server-side — it wraps a session and translates
/// wire results/errors into the typed API + ``RemoteMacError`` the UI consumes.
///
/// **Thin by construction.** All the decision-making — which wire error maps to
/// which ``RemoteMacError``, how a `HistoryEntryDTO` becomes a display row — lives
/// in the pure, tested `SyncCore` layer (`RemoteMacError.from(...)`,
/// `RemoteHistoryItem`). This type only issues the call and forwards the mapping.
///
/// **Foreground-only.** Like sync, it holds no daemon and no background socket:
/// the caller opens a session, drives one or more verbs, and closes it. iOS kills
/// the TLS socket within ~30s of backgrounding, so every method is meant to run
/// while the app is active (the coordinator gates on scene phase).
///
/// **Blocking.** `BridgeSession.call` is synchronous-throwing (it writes a frame
/// and blocks for the response), so these methods are too — run them off the main
/// actor (the coordinator does, via `Task.detached`), exactly like `SyncEngine`.
public final class RemoteMacClient {
    /// Opens a freshly connected + handshaked ``BridgeSession`` to the paired Mac.
    /// Injected so the app supplies the real transport + PSK lookup and tests
    /// supply a fake. Mirrors upstream `BridgeSessionFactory`.
    public typealias SessionProvider = () throws -> any BridgeSession

    private let openSession: SessionProvider

    /// - Parameter sessionProvider: yields a live, handshaked session. Throwing
    ///   here (peer not found, TLS drop, no key) surfaces as
    ///   ``RemoteMacError/unreachable(detail:)`` / ``RemoteMacError/notPaired``.
    public init(sessionProvider: @escaping SessionProvider) {
        self.openSession = sessionProvider
    }

    // MARK: - Verbs

    /// The Mac's current posture (engine/model, whether a session is active, LLM
    /// config + cloud disclosure, history on/off). Cheap; a good reachability +
    /// capability probe before showing the drive controls.
    public func remoteStatus() throws -> BridgeWire.StatusResult {
        try withSession { session in
            try session.call(
                method: BridgeWire.Method.status.rawValue,
                params: Optional<BridgeWire.HelloParams>.none,
                resultType: BridgeWire.StatusResult.self)
        }
    }

    /// Ask the Mac to capture on ITS microphone and return the transcript. With a
    /// `prompt`, the Mac shows its agent-question overlay (+ optional TTS) and the
    /// returned `text` is the human's spoken answer — this IS the
    /// "answer-a-question-from-your-Mac-by-voice" path; no separate verb exists
    /// (ARCHITECTURE §6.6). Blocks until the Mac finishes, times out, or errors.
    public func remoteDictate(
        prompt: String? = nil,
        timeoutSeconds: Int? = nil,
        language: String? = nil
    ) throws -> BridgeWire.DictateResult {
        let params = BridgeWire.DictateParams(
            prompt: prompt, timeoutSeconds: timeoutSeconds, language: language)
        return try withSession { session in
            try session.call(
                method: BridgeWire.Method.dictate.rawValue,
                params: params,
                resultType: BridgeWire.DictateResult.self)
        }
    }

    /// Ask the Mac to stop an in-flight remote dictation and return what it has.
    /// The blocking `remoteDictate` call then returns with `endedBy == .stop`.
    /// Opens its OWN short session (the dictate call is holding the other one).
    @discardableResult
    public func remoteStopDictation() throws -> BridgeWire.DictateStopResult {
        try withSession { session in
            try session.call(
                method: BridgeWire.Method.dictateStop.rawValue,
                params: Optional<BridgeWire.HelloParams>.none,
                resultType: BridgeWire.DictateStopResult.self)
        }
    }

    /// Ask the Mac to cancel an in-flight remote dictation — the blocking
    /// `remoteDictate` throws ``RemoteMacError/dictationCancelled`` (no text, by
    /// the cancel invariant).
    @discardableResult
    public func remoteCancelDictation() throws -> BridgeWire.DictateCancelResult {
        try withSession { session in
            try session.call(
                method: BridgeWire.Method.dictateCancel.rawValue,
                params: Optional<BridgeWire.HelloParams>.none,
                resultType: BridgeWire.DictateCancelResult.self)
        }
    }

    /// Ask the Mac to refine `text` per `instruction` with its configured LLM.
    /// On ``RemoteMacError/llmUnavailable(originalText:)`` the caller's text comes
    /// back so the phone can keep it unrefined.
    public func remoteRefine(text: String, instruction: String) throws -> BridgeWire.RefineResult {
        let params = BridgeWire.RefineParams(text: text, instruction: instruction)
        return try withSession { session in
            try session.call(
                method: BridgeWire.Method.refine.rawValue,
                params: params,
                resultType: BridgeWire.RefineResult.self)
        }
    }

    /// The Mac's recent transcription history (read-only), newest-first, mapped to
    /// display rows. `limit` is clamped server-side (default 20, max 200).
    public func remoteHistory(limit: Int? = nil) throws -> [RemoteHistoryItem] {
        let params = BridgeWire.HistoryListParams(limit: limit)
        let result: BridgeWire.HistoryListResult = try withSession { session in
            try session.call(
                method: BridgeWire.Method.historyList.rawValue,
                params: params,
                resultType: BridgeWire.HistoryListResult.self)
        }
        return RemoteHistoryItem.list(from: result)
    }

    // MARK: - Session lifecycle + error translation

    /// Open a session, run `body`, and close the session — translating every
    /// throw into a ``RemoteMacError``. A session is per-call (like the sync
    /// engine's) so a dropped socket never leaves a stale connection cached; the
    /// TLS-PSK handshake is cheap on the LAN.
    private func withSession<R>(_ body: (any BridgeSession) throws -> R) throws -> R {
        let session: any BridgeSession
        do {
            session = try openSession()
        } catch {
            throw RemoteMacClient.map(error)
        }
        defer { (session as? TCPBridgeSession)?.close() }
        do {
            return try body(session)
        } catch {
            throw RemoteMacClient.map(error)
        }
    }

    /// Translate any error thrown while opening or calling into a
    /// ``RemoteMacError``. The wire-domain mapping is delegated to the pure
    /// `SyncCore` layer; transport/pairing faults map to `unreachable`/`notPaired`
    /// here (they're OS-shaped and can't live in the pure target).
    static func map(_ error: Error) -> RemoteMacError {
        switch error {
        case let e as TCPBridgeSession.SessionError:
            switch e {
            case .notConnected:
                return .unreachable(detail: "not connected")
            case .transport(let m):
                return .unreachable(detail: m)
            case .undecodable(let m):
                return .macError(message: "Unexpected response from your Mac: \(m)")
            case .unsupportedVersion:
                return .unsupportedVersion
            case .domain(let reason, let message):
                return RemoteMacError.from(bridgeCode: reason, message: message)
            }
        case let e as BonjourPeerTransport.TransportError:
            switch e {
            case .peerNotFound:
                return .unreachable(detail: "peer not found on the LAN")
            }
        case let e as RemoteMacError:
            return e
        case let e as BridgeWire.ErrorObject:
            return RemoteMacError.from(bridgeError: e)
        default:
            return .unreachable(detail: error.localizedDescription)
        }
    }
}
