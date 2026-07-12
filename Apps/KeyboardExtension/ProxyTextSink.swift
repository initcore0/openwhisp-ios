import UIKit
import KeyboardCore

/// `KeyboardTextSink` over a `UITextDocumentProxy`. The single adapter between the
/// tested KeyboardCore logic and UIKit's text input; all the "what does the field
/// look like" heuristics live here so the model stays Foundation-only.
///
/// It holds the owning `UIInputViewController` weakly to read `hasFullAccess` and
/// to reach the proxy's `UITextInputTraits` (for the secure-field + return-key
/// signals), which are not exposed directly on `UITextDocumentProxy`.
final class ProxyTextSink: KeyboardTextSink {

    private weak var controller: UIInputViewController?

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    // MARK: - Mutations

    func insert(_ text: String) {
        proxy?.insertText(text)
    }

    func deleteBackward(_ count: Int) {
        guard count > 0, let proxy else { return }
        for _ in 0..<count { proxy.deleteBackward() }
    }

    // MARK: - Context

    var contextBeforeCaret: String? {
        proxy?.documentContextBeforeInput
    }

    /// Map the field's `returnKeyType` to the platform-neutral label enum.
    /// `UITextDocumentProxy` exposes the traits via `UITextInputTraits`.
    var returnKeyLabel: ReturnKeyLabel {
        guard let type = traits?.returnKeyType else { return .return }
        switch type {
        case .go: return .go
        case .next: return .next
        case .send: return .send
        case .search, .google, .yahoo: return .search
        case .done: return .done
        case .join: return .join
        case .route: return .route
        case .emergencyCall: return .emergencyCall
        case .continue: return .continue
        case .default: return .return
        @unknown default: return .return
        }
    }

    /// A field is "secure" when it's a password entry. iOS signals this via
    /// `isSecureTextEntry`; a password `textContentType` is a corroborating signal
    /// for fields that don't set the secure flag but still shouldn't receive a
    /// stale dictation.
    var isSecureField: Bool {
        guard let traits else { return false }
        if traits.isSecureTextEntry == true { return true }
        if #available(iOS 11.0, *) {
            switch traits.textContentType {
            case .some(.password), .some(.newPassword), .some(.oneTimeCode):
                return true
            default:
                break
            }
        }
        return false
    }

    var hasFullAccess: Bool {
        controller?.hasFullAccess ?? false
    }

    /// The field's `autocapitalizationType` trait, projected to the neutral enum.
    /// When the field opts out (`.none`), the model suppresses sentence autocap so
    /// username/URL fields don't get an unwanted leading capital (matches the
    /// system keyboard). Defaults to `.sentences` when the trait is unreadable.
    var autocapType: KeyboardAutocapType {
        switch traits?.autocapitalizationType {
        case .some(.none): return .none
        case .some(.words): return .words
        case .some(.allCharacters): return .allCharacters
        case .some(.sentences): return .sentences
        case .none: return .sentences
        @unknown default: return .sentences
        }
    }

    // MARK: - Traits access

    /// `UITextDocumentProxy` conforms to `UITextInputTraits`, but the compile-time
    /// type doesn't advertise it; cast to reach `returnKeyType`/`isSecureTextEntry`.
    private var traits: UITextInputTraits? {
        proxy as? UITextInputTraits
    }
}
