import Foundation

// MARK: - Keyboard interaction model (ARCHITECTURE §6.4)
//
// The pure, tested decisions behind gestures the UIKit layer *detects* but must
// not *decide*: the backspace long-press repeat cadence, the double-tap-space →
// ". " shortcut, the double-tap-shift → caps-lock shortcut, and the set of
// triggers that make the extension re-resolve the mic key. Keeping these here
// (Foundation-only) means the UIKit shell is a dumb dispatcher and every timing
// rule is covered by `swift test`, not left to a device.

// MARK: - Backspace repeat cadence

/// The accelerating repeat schedule for a held backspace key, matching the iOS
/// system keyboard's feel: a pause before the first repeat, a steady interval
/// that then accelerates the longer the key is held, clamped to a floor so it
/// never becomes uncontrollable.
///
/// Pure and deterministic: given the number of repeats already fired, it returns
/// the delay until the next one. The UIKit layer owns only the timer; every
/// number here is asserted in tests.
public struct BackspaceRepeatCadence: Equatable, Sendable {

    /// Delay from finger-down to the FIRST repeated deletion (the initial one is
    /// emitted immediately on touch-down, so this gates repeat #1).
    public let initialDelay: TimeInterval
    /// The starting interval between repeats once repeating begins.
    public let startInterval: TimeInterval
    /// The fastest the repeat may get (floor).
    public let minInterval: TimeInterval
    /// Multiplier applied to the interval on each successive repeat (< 1 speeds up).
    public let acceleration: Double
    /// After this many repeats, delete whole words instead of characters (the
    /// UIKit layer reads this to switch delete granularity; the model just says
    /// when). iOS accelerates to word-deletion on a long hold.
    public let wordDeletionThreshold: Int

    public static let system = BackspaceRepeatCadence(
        initialDelay: 0.40,
        startInterval: 0.11,
        minInterval: 0.03,
        acceleration: 0.88,
        wordDeletionThreshold: 18
    )

    public init(
        initialDelay: TimeInterval,
        startInterval: TimeInterval,
        minInterval: TimeInterval,
        acceleration: Double,
        wordDeletionThreshold: Int
    ) {
        self.initialDelay = initialDelay
        self.startInterval = startInterval
        self.minInterval = minInterval
        self.acceleration = acceleration
        self.wordDeletionThreshold = wordDeletionThreshold
    }

    /// The delay before firing repeat number `index` (1-based: `index == 1` is the
    /// first repeat after touch-down and uses `initialDelay`; subsequent indices
    /// use the accelerating interval, clamped to `minInterval`).
    public func delay(beforeRepeat index: Int) -> TimeInterval {
        guard index >= 1 else { return initialDelay }
        if index == 1 { return initialDelay }
        // index 2 uses startInterval; each further repeat multiplies by acceleration.
        let steps = index - 2
        let raw = startInterval * pow(acceleration, Double(steps))
        return max(minInterval, raw)
    }

    /// Whether, having already fired `repeatsFired` deletions, the key should now
    /// delete whole words rather than single characters.
    public func deletesWord(afterRepeats repeatsFired: Int) -> Bool {
        repeatsFired >= wordDeletionThreshold
    }
}

// MARK: - Double-tap gestures

/// The pure decisions behind the two double-tap shortcuts the UIKit layer detects
/// by timing two taps on the same key. The shell measures the interval; this type
/// owns the threshold and what each gesture MEANS, so both are tested.
public enum KeyboardGesture {

    /// The maximum gap between two taps for them to count as a double-tap
    /// (matches the platform's ~0.3 s convention). The UIKit layer compares its
    /// measured interval to this.
    public static let doubleTapInterval: TimeInterval = 0.30

    /// Whether two taps `interval` seconds apart form a double-tap.
    public static func isDoubleTap(interval: TimeInterval) -> Bool {
        interval >= 0 && interval <= doubleTapInterval
    }

    // MARK: Double-tap space → ". "

    /// What a double-tap on the space bar should do, given the text immediately
    /// before the caret. iOS turns "word |" (a space then double-tap) into
    /// "word. " — it deletes the auto-inserted trailing space, inserts a period,
    /// then a space. We only do this when the character before the caret is a
    /// single space preceded by a non-terminator word character; otherwise the
    /// double-tap is just two ordinary spaces (the caller already inserted the
    /// first on the initial tap, so a `.plainSpace` means "insert one more space").
    public enum SpaceDoubleTap: Equatable, Sendable {
        /// Replace the trailing space with "." and add a space → net effect
        /// "<word>. ". The UIKit layer performs: deleteBackward(1), insert(". ").
        case periodSpace
        /// Not eligible — treat the second tap as a normal space insertion.
        case plainSpace
    }

    public static func spaceDoubleTap(contextBeforeCaret context: String?) -> SpaceDoubleTap {
        guard let context, let last = context.last, last == " " else {
            return .plainSpace
        }
        // Look at the character before the trailing space.
        let beforeSpace = context.dropLast()
        guard let prev = beforeSpace.last else {
            // The space is at the very start of the field → not a word end.
            return .plainSpace
        }
        // Don't turn ". " or "! " or "? " into ".. "; and require the previous
        // char to be a word character (letter/number) so we only close a word.
        if prev.isLetter || prev.isNumber {
            return .periodSpace
        }
        return .plainSpace
    }

    // MARK: Double-tap shift → caps lock

    /// The shift state a double-tap on shift should produce. Unlike the single-tap
    /// cycle (off→on→capsLock→off), a double-tap ALWAYS lands on caps lock when
    /// starting from off/on, and releases to off when already locked — so a user
    /// double-tapping gets caps lock deterministically without having to know the
    /// cycle position.
    public static func shiftAfterDoubleTap(from current: ShiftState) -> ShiftState {
        switch current {
        case .off, .on: return .capsLock
        case .capsLock: return .off
        }
    }
}

// MARK: - Mic-key refresh triggers

/// The events that make the keyboard re-resolve the mic key against the live
/// handoff state (D8). Enumerated so the extension's re-resolve call sites are a
/// tested contract, not scattered ad-hoc hooks: the R0c return-trip guarantee
/// (keyboard reappears → pending text lands) depends on `viewWillAppear` and
/// `darwinPing` both re-resolving, and the "listening…" indicator depends on the
/// `captureStatePoll` tick while a capture is in flight.
public enum MicKeyRefreshTrigger: String, CaseIterable, Equatable, Sendable {
    /// The keyboard became visible (app-switch return / focus). The reliability
    /// floor for the return-trip insert — always re-resolves.
    case viewWillAppear
    /// A `DarwinHandoffNotifier.onPublished` cross-process ping arrived (host
    /// published a transcript while the keyboard is live). Best-effort; layered
    /// on top of the `viewWillAppear` floor.
    case darwinPing
    /// A periodic tick while the keyboard is visible, used to animate the
    /// "listening…" state and to catch a state change the Darwin ping missed.
    case captureStatePoll
    /// The user tapped the mic key itself.
    case micTap

    /// Whether this trigger should perform an *automatic* insert when the resolver
    /// says `.insertPending` (vs. only updating the visible mic-key state). The
    /// return-trip triggers auto-insert so text lands with no extra tap; a poll
    /// tick must NOT auto-insert (it fires repeatedly and would double-insert as
    /// the state settles), and a mic tap inserts because the user asked.
    public var performsAutoInsert: Bool {
        switch self {
        case .viewWillAppear, .darwinPing, .micTap: return true
        case .captureStatePoll: return false
        }
    }
}
