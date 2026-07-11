import Foundation
import MobileCore

// MARK: - Mic-key behavior (ARCHITECTURE §6.4, decision D8)
//
// The keyboard mic key is a state-aware affordance, NOT a recorder (the keyboard
// has no mic — constraint C1). This pure resolver decides what a tap means, given
// the four inputs of D8's truth table. It is exhaustively tested.

/// What a tap on the keyboard mic key should do.
public enum MicKeyBehavior: Equatable, Sendable {
    /// A fresh, unexpired transcript is waiting — insert it (carries its id).
    case insertPending(id: UUID)
    /// No usable transcript — teach/launch the capture path chosen in WP2.
    case showCaptureUX
    /// Full Access is off — show the explainer sheet (App Group is unreadable
    /// without it, so we can't even see a pending transcript).
    case explainFullAccess
    /// A capture is already running (host is capturing/transcribing) — reflect
    /// that state instead of starting another.
    case showCapturing
}

/// D8, made total. Precedence, top to bottom:
///
/// 1. **Full Access off ⇒ `.explainFullAccess`.** Without it the keyboard can't
///    read the App Group at all, so `pending` is meaningless and we must send the
///    user to the explainer regardless of anything else.
/// 2. **Capture in flight (`.capturing`/`.transcribing`) ⇒ `.showCapturing`.**
///    Don't start a second capture or race an insert while the host is working;
///    reflect the live state. (This outranks a pending transcript because a
///    stale `pending` may still be sitting there from a previous run while a new
///    capture is underway.)
/// 3. **Idle + a fresh, unexpired pending transcript ⇒ `.insertPending(id:)`.**
/// 4. **Idle + no usable transcript (none, or expired) ⇒ `.showCaptureUX`.**
public enum MicKeyResolver {
    public static func resolve(
        fullAccess: Bool,
        captureState: HandoffCaptureState,
        pending: PendingTranscript?,
        now: Date
    ) -> MicKeyBehavior {
        // 1. Full Access gates everything.
        guard fullAccess else {
            return .explainFullAccess
        }

        // 2. A live capture takes precedence over any (possibly stale) pending.
        switch captureState {
        case .capturing, .transcribing:
            return .showCapturing
        case .idle:
            break
        }

        // 3. Idle: a fresh, unexpired transcript is insertable.
        if let pending, !pending.isExpired(now: now) {
            return .insertPending(id: pending.id)
        }

        // 4. Idle with nothing usable (nil or expired) → teach/launch capture.
        return .showCaptureUX
    }
}
