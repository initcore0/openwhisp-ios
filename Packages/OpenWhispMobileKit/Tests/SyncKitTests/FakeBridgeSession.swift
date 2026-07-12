import Foundation
import OpenWhispCore
import OpenWhispBridgeKit
@testable import SyncKit

/// An in-process fake Mac for driving ``RemoteMacClient`` without a network — the
/// WP7 counterpart to ``FakeSyncPeer``. It answers the drive verbs
/// (`status`/`dictate`/`dictate.stop`/`dictate.cancel`/`refine`/`history.list`)
/// from scripted responses, and can be told to throw a specific
/// `TCPBridgeSession.SessionError.domain` (a consent-denied / rate-limited / busy
/// refusal) so error surfacing is proven. Conforms to the upstream
/// `BridgeSession`, so it plugs straight into `RemoteMacClient`.
final class FakeBridgeSession: BridgeSession {
    /// Canned successful results, keyed by wire method. Set what a test needs.
    var status: BridgeWire.StatusResult?
    var dictateResult: BridgeWire.DictateResult?
    var stopResult: BridgeWire.DictateStopResult?
    var cancelResult: BridgeWire.DictateCancelResult?
    var refineResult: BridgeWire.RefineResult?
    var historyResult: BridgeWire.HistoryListResult?

    /// If set for a method, that call throws this domain error instead of
    /// returning a result — the same shape `TCPBridgeSession` raises on a bridge
    /// refusal.
    var domainErrors: [String: (reason: BridgeWire.ErrorCode?, message: String)] = [:]

    /// Records every method called, in order, for assertions.
    private(set) var calls: [String] = []
    /// Records the decoded params of the last `dictate`/`refine` for assertions.
    private(set) var lastDictateParams: BridgeWire.DictateParams?
    private(set) var lastRefineParams: BridgeWire.RefineParams?
    private(set) var lastHistoryParams: BridgeWire.HistoryListParams?

    var offersCapabilities = true
    private(set) var handshakeCount = 0
    private(set) var closed = false

    func handshake(clientName: String) throws {
        handshakeCount += 1
    }

    func call<P, R>(method: String, params: P?, resultType: R.Type) throws -> R
        where P: Codable & Sendable, R: Decodable
    {
        calls.append(method)

        if let err = domainErrors[method] {
            throw TCPBridgeSession.SessionError.domain(reason: err.reason, message: err.message)
        }

        // Capture params by round-tripping through JSON (exercises the same
        // encode path the real transport uses).
        if let params, let data = try? JSONEncoder().encode(params) {
            switch method {
            case BridgeWire.Method.dictate.rawValue:
                lastDictateParams = try? JSONDecoder().decode(BridgeWire.DictateParams.self, from: data)
            case BridgeWire.Method.refine.rawValue:
                lastRefineParams = try? JSONDecoder().decode(BridgeWire.RefineParams.self, from: data)
            case BridgeWire.Method.historyList.rawValue:
                lastHistoryParams = try? JSONDecoder().decode(BridgeWire.HistoryListParams.self, from: data)
            default: break
            }
        }

        let result: Any?
        switch method {
        case BridgeWire.Method.status.rawValue:       result = status
        case BridgeWire.Method.dictate.rawValue:      result = dictateResult
        case BridgeWire.Method.dictateStop.rawValue:  result = stopResult
        case BridgeWire.Method.dictateCancel.rawValue: result = cancelResult
        case BridgeWire.Method.refine.rawValue:       result = refineResult
        case BridgeWire.Method.historyList.rawValue:  result = historyResult
        default:
            throw TCPBridgeSession.SessionError.domain(reason: .unknownMethod, message: "unknown method \(method)")
        }

        guard let typed = result as? R else {
            throw TCPBridgeSession.SessionError.undecodable("fake had no scripted result for \(method)")
        }
        return typed
    }

    func close() { closed = true }
}
