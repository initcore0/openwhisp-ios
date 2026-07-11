import Foundation

// MARK: - Keyboard text sink (ARCHITECTURE §6.4)
//
// Everything the keyboard does to text, abstracted off `UITextDocumentProxy` so
// KeyboardCore stays Foundation-only and fully testable. The extension provides
// the concrete `ProxyTextSink` (WP4). Tests provide a fake conforming type.

/// The label the host wants on the keyboard's return key. The keyboard mirrors
/// the field's `returnKeyType`; this enum is the platform-neutral projection of
/// the common cases.
public enum ReturnKeyLabel: String, Equatable, Sendable {
    case `return`
    case go
    case next
    case send
    case search
    case done
    case join
    case route
    case emergencyCall
    case `continue`
}

/// The keyboard's interface to the text field, abstracted for testability.
public protocol KeyboardTextSink: AnyObject {
    func insert(_ text: String)
    func deleteBackward(_ count: Int)
    /// `documentContextBeforeInput` — the text immediately before the caret.
    var contextBeforeCaret: String? { get }
    var returnKeyLabel: ReturnKeyLabel { get }
    /// `secureTextEntry`/`UITextContentType` heuristic — true for password fields.
    var isSecureField: Bool { get }
    /// Whether Full Access is granted (unlocks App Group + LAN, constraint C2).
    var hasFullAccess: Bool { get }
}
