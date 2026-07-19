import Foundation

// MARK: - Deep-link routing (MobileCore) — the floor-flow entry point
//
// The floor dictation flow (ARCHITECTURE §5.2) is entered when something opens
// the host app on the `openwhisp://` URL scheme. The KEYBOARD cannot open the
// host [C9], so in production this URL is delivered by the user (a Shortcut, a
// Home-Screen quick action, or — on simulator — `xcrun simctl openurl`). The
// parsing is a pure, total function so the whole route table is `swift test`-able
// with no app running: every URL maps to exactly one `DeepLink` case, and
// anything we don't understand is `.unknown` (never a crash, never a silent
// wrong route).

/// A parsed `openwhisp://` deep link. Total: an unrecognized URL is `.unknown`,
/// so callers `switch` exhaustively and can never fall into undefined behavior.
public enum DeepLink: Equatable, Sendable {
    /// `openwhisp://dictate` — present the compact dictation sheet and begin a
    /// keyboard-handoff capture (floor flow). This is the ONLY side-effectful
    /// route today; more may be added, but each must be explicit here.
    case dictate
    /// `openwhisp://session/arm` — arm a Dictation Session (WP10, D11): the one
    /// foreground hop that opens the arming screen and activates the background audio
    /// session. Delivered by the user (a Shortcut / Home-Screen action); the keyboard
    /// cannot open it [C9]. Extra path/query is ignored, like `.dictate`.
    case sessionArm
    /// A well-formed `openwhisp://` URL whose host we don't route, or any URL
    /// that isn't the OpenWhisp scheme at all. Carries the raw string for logging.
    case unknown(String)

    /// The URL scheme the host app registers (project.yml `CFBundleURLTypes`).
    public static let scheme = "openwhisp"

    /// Parse a URL into a route. Case-insensitive on scheme and host (URL hosts
    /// are lowercased by `URLComponents` anyway, but we don't rely on that).
    ///
    /// Recognized:
    ///   - `openwhisp://dictate`        → `.dictate`
    ///   - `openwhisp://dictate/…?…`    → `.dictate` (extra path/query ignored)
    /// Everything else (other host, other scheme, unparseable) → `.unknown`.
    public static func parse(_ url: URL) -> DeepLink {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == Self.scheme else {
            return .unknown(url.absoluteString)
        }
        switch components.host?.lowercased() {
        case "dictate":
            return .dictate
        case "session":
            // `openwhisp://session/arm` → arm. Any other/absent path under `session`
            // is unrouted (future session verbs must be added explicitly here).
            let verb = components.path
                .split(separator: "/", omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .lowercased()
            return verb == "arm" ? .sessionArm : .unknown(url.absoluteString)
        default:
            return .unknown(url.absoluteString)
        }
    }

    /// Convenience string overload (some call sites hold a raw string, e.g. a
    /// launch argument). A string that isn't a valid URL is `.unknown`.
    public static func parse(_ string: String) -> DeepLink {
        guard let url = URL(string: string) else { return .unknown(string) }
        return parse(url)
    }

    /// The canonical URL for a route (for building links in Shortcuts guidance,
    /// tests, and the Control Center control's `openAppWhenRun` fallback).
    public var url: URL? {
        switch self {
        case .dictate:
            return URL(string: "\(Self.scheme)://dictate")
        case .sessionArm:
            return URL(string: "\(Self.scheme)://session/arm")
        case .unknown:
            return nil
        }
    }
}
