import Foundation

// MARK: - Live Activity content model (MobileCore) — pure, testable
//
// The hero flow (ARCHITECTURE §5.1) shows a Live Activity / Dynamic Island while
// the host captures. `ActivityKit.ActivityAttributes` is iOS-only and lives in the
// widget/CaptureKit layer, but the DATA it carries — and the mapping from the
// capture pipeline's `CaptureState` to a display phase — is pure Foundation, so it
// lives here and is `swift test`-covered. The iOS `ActivityAttributes` type simply
// wraps `DictationActivityState` as its `ContentState`.

/// The coarse display phase the Live Activity / Dynamic Island renders. Distinct
/// from `CaptureState` (which is richer and host-internal): the activity only needs
/// to know what to draw, and the terminal `.inserted` state is an activity concept
/// (the transcript was published/handed off) not a capture-pipeline one.
public enum DictationActivityPhase: String, Codable, Hashable, Sendable {
    case starting
    case listening
    case transcribing
    /// Terminal success: the transcript was published to the App Group; the
    /// activity shows a brief "Inserted" confirmation, then ends.
    case inserted
    case failed
    /// A Dictation Session is ARMED but idle (WP10, D11): the mic session is held in
    /// the background and the keyboard mic key starts capture instantly. Distinct
    /// from `.starting` — this is a persistent state, not a capture warm-up — and
    /// carries the End Session button rather than a Stop button.
    case armed
}

/// The Live Activity's dynamic content: the phase plus the live input level (for
/// the "listening" meter). `Codable`/`Sendable` so it is exactly the shape an iOS
/// `ActivityAttributes.ContentState` needs, with zero UIKit/ActivityKit imports.
public struct DictationActivityState: Codable, Hashable, Sendable {
    public var phase: DictationActivityPhase
    /// Normalized input level (0…1), meaningful only in `.listening`.
    public var level: Float

    public init(phase: DictationActivityPhase, level: Float = 0) {
        self.phase = phase
        self.level = level
    }

    /// Map a capture-pipeline `CaptureState` to the activity's content state. This
    /// is the single source of truth for "what does the Dynamic Island show for a
    /// given capture state", so it is tested rather than duplicated in the widget.
    ///
    /// `.idle` maps to `.starting` because the activity should never be started for
    /// an idle capture — a caller that maps idle is asking for the pre-listening
    /// look. `.published` maps to `.inserted` (the transcript handed off).
    public static func from(_ state: CaptureState) -> DictationActivityState {
        switch state {
        case .idle:
            return DictationActivityState(phase: .starting)
        case .preparing:
            return DictationActivityState(phase: .starting)
        case .listening(let level):
            return DictationActivityState(phase: .listening, level: level)
        case .transcribing:
            return DictationActivityState(phase: .transcribing)
        case .published:
            return DictationActivityState(phase: .inserted)
        case .failed:
            return DictationActivityState(phase: .failed)
        }
    }

    /// Map a cross-process `SessionStatus.Phase` (WP10b) to the activity's content
    /// state, for the SESSION Live Activity (armed window + live capture). `.off` maps
    /// to `.inserted` only as a terminal placeholder — the driver ends the activity on
    /// `.off` rather than pushing this — so callers should end, not update, for off.
    public static func fromSession(_ phase: SessionStatus.Phase) -> DictationActivityState {
        switch phase {
        case .off: return DictationActivityState(phase: .inserted)
        case .armed: return DictationActivityState(phase: .armed)
        case .capturing: return DictationActivityState(phase: .listening)
        case .transcribing: return DictationActivityState(phase: .transcribing)
        }
    }

    /// Whether this state is terminal (the activity should end shortly after
    /// showing it). Both success (`.inserted`) and `.failed` are terminal.
    public var isTerminal: Bool {
        phase == .inserted || phase == .failed
    }

    /// Whether this is a persistent Dictation-Session state (armed window) whose
    /// activity action is "End Session", not "Stop". `.armed` is the idle held
    /// session; a capturing/transcribing session still shows Stop for the capture.
    public var isSessionArmed: Bool { phase == .armed }

    /// A short human label for the compact/expanded presentations.
    public var label: String {
        switch phase {
        case .starting: return "Starting\u{2026}"
        case .listening: return "Listening\u{2026}"
        case .transcribing: return "Transcribing\u{2026}"
        case .inserted: return "Inserted"
        case .failed: return "Dictation failed"
        case .armed: return "Session on"
        }
    }

    /// The SF Symbol name each phase draws (compact leading + expanded icon).
    public var symbolName: String {
        switch phase {
        case .starting: return "mic"
        case .listening: return "waveform"
        case .transcribing: return "ellipsis"
        case .inserted: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .armed: return "mic.circle.fill"
        }
    }
}
