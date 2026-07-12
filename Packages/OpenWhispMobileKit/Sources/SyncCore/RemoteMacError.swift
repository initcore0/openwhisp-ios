import Foundation
import OpenWhispCore

/// The user-facing failure model for driving the paired Mac's tools over the
/// bridge (WP7, ARCHITECTURE §6.6). Every way a `dictate`/`refine`/`history`/
/// `status` call can fail — a `BridgeWire` domain error, a transport drop, an
/// unreachable/unpaired Mac — collapses into ONE of these cases, each carrying a
/// short human sentence for the UI.
///
/// Foundation-only + tested in the fast gate: the OS-bound `RemoteMacClient`
/// stays thin because ALL the decision-making — which wire error becomes which
/// case, what message to show — lives here in ``RemoteMacError/from(bridgeCode:)``
/// and the initializers below.
public enum RemoteMacError: Error, Equatable, Sendable {
    /// A human/agent session already holds the Mac's mic — the human always wins.
    /// The caller may retry shortly.
    case macBusy
    /// This phone hit its dictation rate limit on the Mac. `retryAfterSeconds` is
    /// the whole-seconds wait the Mac reported (nil when it didn't say).
    case rateLimited(retryAfterSeconds: Int?)
    /// The user (or a stored policy) on the Mac denied this scope
    /// (dictate/refine/history). Re-grant on the Mac to proceed.
    case consentDenied
    /// A dictation was cancelled (Esc on the Mac / an explicit cancel) — no text.
    case dictationCancelled
    /// `timeoutSeconds` elapsed with nothing transcribed on the Mac.
    case dictationTimedOut
    /// The Mac's microphone permission isn't granted; the bridge won't raise the
    /// TCC prompt on the phone's behalf.
    case micPermissionNeeded
    /// A secure text field was focused on the Mac; remote dictation refuses.
    case secureField
    /// No usable LLM on the Mac (unconfigured / model missing / generation
    /// failed). `originalText` is the caller's text handed back so the phone can
    /// keep it unrefined.
    case llmUnavailable(originalText: String?)
    /// Agent-initiated cloud LLM use is disabled on the Mac (OpenAI provider +
    /// "Allow agents to use cloud AI" off).
    case cloudRefineDisabled
    /// History is turned off on the Mac; `history.list` returns nothing.
    case historyDisabled
    /// The Mac isn't paired (no key), or its record vanished — re-pair to drive it.
    case notPaired
    /// Couldn't reach the Mac on this Wi-Fi (asleep / not found / TLS drop /
    /// socket gone). The `detail` is a short technical note for the journal.
    case unreachable(detail: String)
    /// The Mac's OpenWhisp is too old to speak this wire.
    case unsupportedVersion
    /// Any other server-reported failure, carrying the Mac's own message.
    case macError(message: String)

    /// A short, first-person, actionable sentence for the UI. Never leaks NSError
    /// bridge noise — the Mac's own `message` is preferred where it carries one.
    public var userMessage: String {
        switch self {
        case .macBusy:
            return "Your Mac is busy dictating right now. Try again in a moment."
        case .rateLimited(let after):
            if let after, after > 0 {
                return "Too many requests. Try again in \(after)s."
            }
            return "Too many requests to your Mac. Try again shortly."
        case .consentDenied:
            return "Your Mac declined this request. Allow it in OpenWhisp on your Mac, then try again."
        case .dictationCancelled:
            return "Dictation was cancelled on your Mac."
        case .dictationTimedOut:
            return "Your Mac heard nothing before the timeout."
        case .micPermissionNeeded:
            return "Your Mac needs microphone permission. Grant it in System Settings on the Mac."
        case .secureField:
            return "Your Mac has a password field focused, so it won't dictate. Move focus and retry."
        case .llmUnavailable:
            return "Your Mac has no usable AI model for refine right now."
        case .cloudRefineDisabled:
            return "Cloud refine is disabled on your Mac. Enable \u{201C}Allow agents to use cloud AI\u{201D} there."
        case .historyDisabled:
            return "History is turned off on your Mac."
        case .notPaired:
            return "No key stored for this Mac. Re-pair to drive it."
        case .unreachable:
            return "Couldn't reach your Mac on this Wi-Fi. Make sure OpenWhisp is open on it."
        case .unsupportedVersion:
            return "Your Mac's OpenWhisp is too old for this. Update it."
        case .macError(let message):
            return message
        }
    }

    // MARK: - Mapping from the wire

    /// Map a `BridgeWire.ErrorCode` (the `reason` on a domain error) to a
    /// ``RemoteMacError``. The Mac's `message` is threaded through so the
    /// catch-all (`macError`) and unmapped-but-known cases keep the real text;
    /// `retryAfterSeconds`/`originalText` come from the wire's `ErrorData`.
    ///
    /// A `nil` code (a `reason` string a newer Mac introduced that this build
    /// can't decode — `ErrorData` decodes it as nil, by design) falls through to
    /// ``RemoteMacError/macError(message:)`` so the Mac's own sentence still shows
    /// rather than a generic dead-end.
    public static func from(
        bridgeCode code: BridgeWire.ErrorCode?,
        message: String,
        retryAfterSeconds: Int? = nil,
        originalText: String? = nil
    ) -> RemoteMacError {
        guard let code else { return .macError(message: message) }
        switch code {
        case .busy:                 return .macBusy
        case .rateLimited:          return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case .consentDenied:        return .consentDenied
        case .cancelled:            return .dictationCancelled
        case .timeout:              return .dictationTimedOut
        case .micPermissionNeeded:  return .micPermissionNeeded
        case .secureField:          return .secureField
        case .llmUnavailable:       return .llmUnavailable(originalText: originalText)
        case .cloudRefineDisabled:  return .cloudRefineDisabled
        case .historyDisabled:      return .historyDisabled
        case .unsupportedVersion:   return .unsupportedVersion
        case .audioUnavailable:     return .unreachable(detail: message)
        // Codes that describe a protocol/server fault rather than a distinct UI
        // state: surface the Mac's own message verbatim.
        case .unsupportedFormat, .malformedRequest, .unknownMethod, .internalError:
            return .macError(message: message)
        }
    }

    /// Map a `BridgeWire.ErrorObject` directly (pulls `reason` +
    /// `retryAfterSeconds` + `originalText` out of its `data`).
    public static func from(bridgeError error: BridgeWire.ErrorObject) -> RemoteMacError {
        from(
            bridgeCode: error.data?.reason,
            message: error.message,
            retryAfterSeconds: error.data?.retryAfterSeconds,
            originalText: error.data?.originalText
        )
    }
}
