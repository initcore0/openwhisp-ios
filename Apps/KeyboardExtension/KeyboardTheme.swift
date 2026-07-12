import UIKit

/// Visual constants for the keyboard, resolved for the current width class and
/// trait collection (light/dark handled by UIKit's dynamic colors). Kept in one
/// place so the look is consistent and easy to tune; no logic lives here.
struct KeyboardTheme {

    /// Metrics scale with the horizontal size class: iPad keys are taller with
    /// more breathing room than the iPhone's.
    struct Metrics {
        let rowHeight: CGFloat
        let keySpacing: CGFloat
        let rowSpacing: CGFloat
        let sideInset: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat
        let keyCornerRadius: CGFloat
        let letterFontSize: CGFloat
        let controlFontSize: CGFloat

        /// iPhone metrics (compact width). Portrait and landscape share these; the
        /// row height is trimmed a little in landscape to fit the shorter height.
        static func phone(landscape: Bool) -> Metrics {
            Metrics(
                rowHeight: landscape ? 38 : 44,
                keySpacing: 6,
                rowSpacing: landscape ? 8 : 11,
                sideInset: 3,
                topInset: landscape ? 5 : 8,
                bottomInset: landscape ? 4 : 6,
                keyCornerRadius: 5,
                letterFontSize: landscape ? 20 : 22,
                controlFontSize: 16
            )
        }

        /// iPad metrics (regular width): larger caps, more spacing.
        static func pad() -> Metrics {
            Metrics(
                rowHeight: 58,
                keySpacing: 10,
                rowSpacing: 12,
                sideInset: 6,
                topInset: 10,
                bottomInset: 8,
                keyCornerRadius: 7,
                letterFontSize: 26,
                controlFontSize: 20
            )
        }
    }

    static func metrics(for traits: UITraitCollection) -> Metrics {
        if traits.userInterfaceIdiom == .pad || traits.horizontalSizeClass == .regular {
            return .pad()
        }
        let landscape = traits.verticalSizeClass == .compact
        return .phone(landscape: landscape)
    }

    // MARK: - Colors
    //
    // System keyboards use two key fills: a light "letter" cap and a slightly
    // darker "control" cap (shift, backspace, page toggles). We approximate that
    // with dynamic colors so light/dark both look native. `keyboardAppearance`
    // (dark override for content over dark UIs) is handled by the input view's
    // trait collection, so these dynamic colors resolve correctly.

    /// The whole keyboard's backdrop (matches the system input-view grey).
    static let backdrop = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.12, alpha: 1.0)
            : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1.0)
    }

    /// A letter key's resting fill.
    static let letterKey = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1.0)
            : UIColor.white
    }

    /// A control key's resting fill (shift, backspace, 123, return background).
    static let controlKey = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.26, alpha: 1.0)
            : UIColor(red: 0.68, green: 0.71, blue: 0.74, alpha: 1.0)
    }

    /// A key's fill while pressed (letters invert toward the control color for a
    /// visible press; controls brighten).
    static let letterKeyPressed = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.30, alpha: 1.0)
            : UIColor(red: 0.80, green: 0.82, blue: 0.85, alpha: 1.0)
    }

    static let controlKeyPressed = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.42, alpha: 1.0)
            : UIColor.white
    }

    /// An active/latched control (shift engaged, caps lock) uses the letter fill so
    /// it reads as "lit".
    static let activeControlKey = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.55, alpha: 1.0)
            : UIColor.white
    }

    /// The mic key's accent when a dictation affordance is live.
    static let accent = UIColor.systemBlue

    static let keyText = UIColor.label
    static let controlKeyText = UIColor.label

    /// Subtle shadow under each cap (system keyboards have a 1pt drop shadow).
    static let keyShadow = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.0, alpha: 0.6)
            : UIColor(white: 0.5, alpha: 0.5)
    }

    /// The popup bubble fill (letter preview on press).
    static let popupFill = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.5, alpha: 1.0)
            : UIColor.white
    }
}
