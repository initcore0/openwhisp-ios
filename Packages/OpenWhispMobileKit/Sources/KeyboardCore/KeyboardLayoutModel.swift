import Foundation

// MARK: - Keyboard layout model (ARCHITECTURE §6.4)
//
// Pure keyboard model: layout pages (letters/symbols/numbers), shift state
// (off/on/capsLock), autocap after sentence breaks, and key-action resolution.
// The UIKit layer (WP4) is dumb: it renders rows from `currentRows()` and turns
// a touch into a `KeyAction`, then calls `apply(_:)`. No UIKit here → testable.

/// Which page of keys is showing.
public enum LayoutPage: String, Equatable, Sendable {
    case letters   // QWERTY
    case symbols   // #+= punctuation
    case numbers   // 123 + common punctuation
}

/// The shift key's three-way state.
public enum ShiftState: String, Equatable, Sendable {
    case off
    case on         // one-shot: next letter uppercased, then back to off
    case capsLock   // sticky: every letter uppercased until toggled off
}

/// A resolved key action, produced by the UI layer from a touch and applied to
/// the model (and/or forwarded to the text sink by the extension).
public enum KeyAction: Equatable, Sendable {
    case character(String)
    case backspace
    case shift
    case globe
    case returnKey
    case space
    case page(LayoutPage)
    case mic
    case refineLast
}

/// The pure keyboard state machine.
public struct KeyboardLayoutModel: Equatable, Sendable {

    public private(set) var page: LayoutPage
    public private(set) var shift: ShiftState
    /// Whether automatic capitalization is enabled (from `KeyboardConfig`).
    public var autocapEnabled: Bool

    public init(page: LayoutPage = .letters, shift: ShiftState = .on, autocapEnabled: Bool = true) {
        self.page = page
        self.shift = shift
        self.autocapEnabled = autocapEnabled
    }

    // MARK: - Applying actions

    /// The character that a `.character` action should actually emit, given the
    /// current shift state, plus the resulting model after emission (shift may
    /// fall from `.on` back to `.off`). Returns nil for the emitted string when
    /// the action is not a character (the caller handles those separately).
    ///
    /// This is the single source of truth for "what does pressing this key type".
    public mutating func apply(_ action: KeyAction) -> KeyOutput {
        switch action {
        case .character(let base):
            let emitted = renderedCharacter(base)
            // A one-shot shift consumes on the next character.
            if shift == .on {
                shift = .off
            }
            return .text(emitted)

        case .space:
            // A one-shot shift does NOT survive a space in this model
            // (space is not a letter); caps lock persists.
            if shift == .on {
                shift = .off
            }
            return .text(" ")

        case .backspace:
            return .deleteBackward

        case .shift:
            shift = nextShiftState(from: shift)
            return .none

        case .page(let target):
            page = target
            // Leaving the letters page drops a one-shot shift; caps lock is a
            // letters-page concept, so normalize it off when we leave.
            if target != .letters, shift != .off {
                shift = .off
            }
            return .none

        case .returnKey:
            return .submitReturn

        case .globe:
            return .switchInputMode

        case .mic:
            return .micTapped

        case .refineLast:
            return .refineLastTapped
        }
    }

    /// After the sink's text changes, the extension calls this so autocap can
    /// re-arm the shift at a sentence start. `contextBeforeCaret` is the text
    /// immediately before the caret (may be nil/empty at field start).
    ///
    /// Rules:
    /// - autocap only ever sets a ONE-SHOT shift (`.on`), never caps lock, and
    ///   never overrides an explicit caps lock the user engaged.
    /// - it arms at the start of a field, or after a sentence terminator followed
    ///   by whitespace.
    /// - it disarms (`.off`) mid-word so lowercase continues naturally.
    public mutating func updateAutocap(contextBeforeCaret context: String?) {
        guard autocapEnabled else { return }
        // Never fight a deliberate caps lock.
        if shift == .capsLock { return }

        if isSentenceStart(context: context) {
            shift = .on
        } else {
            shift = .off
        }
    }

    // MARK: - Rendering

    /// The rows of keys to display for the current page. The UI renders these;
    /// letter rows honor the shift state for casing.
    public func currentRows() -> [[String]] {
        switch page {
        case .letters:
            let rows = Self.letterRows
            let upper = (shift != .off)
            return rows.map { row in row.map { upper ? $0.uppercased() : $0 } }
        case .symbols:
            return Self.symbolRows
        case .numbers:
            return Self.numberRows
        }
    }

    // MARK: - Internals

    /// The output of applying an action, for the extension to act on.
    public enum KeyOutput: Equatable, Sendable {
        case text(String)
        case deleteBackward
        case submitReturn
        case switchInputMode
        case micTapped
        case refineLastTapped
        case none
    }

    private func renderedCharacter(_ base: String) -> String {
        // Only letters are cased by shift; digits/symbols pass through.
        guard page == .letters else { return base }
        return (shift != .off) ? base.uppercased() : base
    }

    /// Shift key press cycle: off → on → capsLock → off.
    ///
    /// (A double-tap-to-caps-lock affordance is a UI concern layered on top; the
    /// model exposes the deterministic three-way cycle so both a single-tap cycle
    /// and a double-tap shortcut can drive it.)
    private func nextShiftState(from s: ShiftState) -> ShiftState {
        switch s {
        case .off: return .on
        case .on: return .capsLock
        case .capsLock: return .off
        }
    }

    private func isSentenceStart(context: String?) -> Bool {
        guard let context, !context.isEmpty else { return true }
        // Walk back over trailing whitespace.
        let reversed = context.reversed()
        var sawWhitespace = false
        for ch in reversed {
            if ch.isWhitespace {
                sawWhitespace = true
                continue
            }
            // First non-space char found.
            if Self.sentenceTerminators.contains(ch) {
                // Terminator must be followed by whitespace to count as a break
                // (so "e.g" mid-word doesn't autocap). At field start it's a
                // sentence start regardless.
                return sawWhitespace
            }
            return false
        }
        // All whitespace → treat as field start.
        return true
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    // MARK: - Static layouts (English QWERTY v1, D4)

    static let letterRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    static let numberRows: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]

    static let symbolRows: [[String]] = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]
}
