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

// MARK: - Session-aware mic-key behavior (ARCHITECTURE §6.8, decision D11)
//
// With Dictation Sessions (WP10), the mic key gains a live-remote-control meaning
// while a session is armed. This does NOT replace the floor flow — when NO session
// is live (off, or a stale/dead host) the key behaves exactly as before, so the
// resolver DELEGATES to `MicKeyResolver.resolve` for that case. That keeps every
// existing (non-session) behavior semantic intact.

/// What a tap on the mic key means when a session may be armed.
public enum SessionMicKeyBehavior: Equatable, Sendable {
    /// No live session — do today's floor flow (the exact `MicKeyBehavior` the
    /// non-session resolver produced: insert a pending, show capture UX, etc.).
    case startSessionHop(MicKeyBehavior)
    /// An armed session is idle — post `startCapture` to begin live dictation.
    case startCapture
    /// A capture is running — post `stopCapture` to finish it.
    case stopCapture
    /// Full Access is off — show the explainer; session features are invisible.
    case explainFullAccess
    /// The final is being transcribed — reflect that; a tap starts nothing new.
    case showTranscribing
}

extension MicKeyResolver {
    /// Session-aware resolution. Precedence, top to bottom:
    ///
    /// 1. **Full Access off ⇒ `.explainFullAccess`.** As in the floor flow — the
    ///    App Group is unreadable, so nothing else can be known.
    /// 2. **Live session phase (after the 30 s staleness fence).**
    ///    - `.armed` ⇒ `.startCapture` (begin live dictation).
    ///    - `.capturing` ⇒ `.stopCapture` (finish it).
    ///    - `.transcribing` ⇒ `.showTranscribing` (the final is wrapping up).
    /// 3. **`.off` (no session, OR a stale/dead host) ⇒ `.startSessionHop(_:)`**
    ///    carrying the floor-flow behavior from `resolve(...)` — the mic key is
    ///    unchanged when no session is live, per D11 ("no session: today's floor
    ///    flow").
    ///
    /// The staleness fence lives in `SessionStatus.effectivePhase(now:)`: a
    /// live phase whose heartbeat is older than 30 s collapses to `.off`, so a
    /// jetsammed host can never present a live mic key.
    public static func resolveSession(
        fullAccess: Bool,
        sessionStatus: SessionStatus,
        captureState: HandoffCaptureState,
        pending: PendingTranscript?,
        now: Date
    ) -> SessionMicKeyBehavior {
        // 1. Full Access gates everything (same as the floor flow).
        guard fullAccess else {
            return .explainFullAccess
        }

        // 2. A live session (after the staleness fence) drives the key.
        switch sessionStatus.effectivePhase(now: now) {
        case .armed:
            return .startCapture
        case .capturing:
            return .stopCapture
        case .transcribing:
            return .showTranscribing
        case .off:
            // 3. No live session → delegate to today's floor flow unchanged.
            return .startSessionHop(
                resolve(fullAccess: fullAccess, captureState: captureState, pending: pending, now: now)
            )
        }
    }
}
