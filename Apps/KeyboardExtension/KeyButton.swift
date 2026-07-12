import UIKit
import KeyboardCore

/// One key cap. A dumb view: it knows its `KeyAction`, its label, and how to draw
/// itself resting / pressed / latched. Touch tracking and gesture semantics live
/// in `KeyboardView`; this view only reflects state and shows the letter popup.
final class KeyButton: UIView {

    /// What kind of cap this is, driving its resting fill and whether it pops up.
    enum Kind {
        case letter        // pops up a preview on press (iPhone)
        case control       // shift, backspace, 123, symbols, globe, return
        case space
        case mic
    }

    let action: KeyAction
    let kind: Kind

    /// Whether this control is latched "on" (shift engaged / caps lock), which
    /// lights the cap. Ignored for non-control kinds.
    var isLatched: Bool = false { didSet { updateAppearance() } }

    /// A caps-lock indicator line under the shift glyph.
    var showsCapsLockIndicator: Bool = false { didSet { setNeedsDisplay() } }

    private let label = UILabel()
    private var iconView: UIImageView?
    private let metrics: KeyboardTheme.Metrics

    private(set) var isPressed = false

    private var popup: KeyPopupView?

    init(action: KeyAction, kind: Kind, title: String?, systemImage: String?, metrics: KeyboardTheme.Metrics) {
        self.action = action
        self.kind = kind
        self.metrics = metrics
        super.init(frame: .zero)

        layer.cornerRadius = metrics.keyCornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = KeyboardTheme.keyShadow.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 1
        isUserInteractionEnabled = false   // KeyboardView does the touch tracking.

        if let systemImage, let image = UIImage(systemName: systemImage) {
            let iv = UIImageView(image: image)
            iv.tintColor = KeyboardTheme.controlKeyText
            iv.contentMode = .center
            iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: metrics.controlFontSize, weight: .regular)
            iv.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iv)
            NSLayoutConstraint.activate([
                iv.centerXAnchor.constraint(equalTo: centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            iconView = iv
        } else {
            label.text = title
            label.textAlignment = .center
            label.textColor = (kind == .letter) ? KeyboardTheme.keyText : KeyboardTheme.controlKeyText
            label.font = .systemFont(
                ofSize: kind == .letter ? metrics.letterFontSize : metrics.controlFontSize,
                weight: kind == .letter ? .regular : .regular
            )
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            ])
        }

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// The visible glyph (for the popup preview and for accessibility).
    var displayTitle: String? {
        label.text
    }

    func setTitle(_ title: String) {
        label.text = title
    }

    // MARK: - Press state

    func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        isPressed = pressed
        updateAppearance()
        if kind == .letter {
            pressed ? showPopup() : hidePopup()
        }
    }

    // MARK: - Appearance

    private func updateAppearance() {
        let fill: UIColor
        switch kind {
        case .letter:
            fill = isPressed ? KeyboardTheme.letterKeyPressed : KeyboardTheme.letterKey
        case .space:
            fill = isPressed ? KeyboardTheme.controlKeyPressed : KeyboardTheme.letterKey
        case .mic:
            fill = isPressed ? KeyboardTheme.controlKeyPressed : KeyboardTheme.controlKey
        case .control:
            if isLatched {
                fill = KeyboardTheme.activeControlKey
            } else {
                fill = isPressed ? KeyboardTheme.controlKeyPressed : KeyboardTheme.controlKey
            }
        }
        backgroundColor = fill
        // A latched shift lights its glyph in the accent color; caps lock too.
        if kind == .control, isLatched, case .shift = action {
            iconView?.tintColor = KeyboardTheme.keyText
        } else {
            iconView?.tintColor = KeyboardTheme.controlKeyText
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        layer.shadowColor = KeyboardTheme.keyShadow.cgColor
    }

    // MARK: - Caps-lock indicator (a bar under the shift arrow)

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard showsCapsLockIndicator, let ctx = UIGraphicsGetCurrentContext() else { return }
        let barWidth: CGFloat = bounds.width * 0.36
        let barHeight: CGFloat = 2
        let x = (bounds.width - barWidth) / 2
        let y = bounds.height - 10
        ctx.setFillColor(KeyboardTheme.keyText.cgColor)
        ctx.fill(CGRect(x: x, y: y, width: barWidth, height: barHeight))
    }

    // MARK: - Letter popup

    private func showPopup() {
        guard let superview, let title = displayTitle, !title.isEmpty else { return }
        // Popups are an iPhone affordance; skip on the roomy iPad.
        if traitCollection.userInterfaceIdiom == .pad { return }
        hidePopup()
        let p = KeyPopupView(text: title, metrics: metrics)
        p.translatesAutoresizingMaskIntoConstraints = false
        superview.addSubview(p)
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: centerXAnchor),
            p.bottomAnchor.constraint(equalTo: topAnchor, constant: 4),
            p.widthAnchor.constraint(greaterThanOrEqualTo: widthAnchor, multiplier: 1.25),
            p.heightAnchor.constraint(equalToConstant: metrics.rowHeight * 1.35),
        ])
        popup = p
    }

    private func hidePopup() {
        popup?.removeFromSuperview()
        popup = nil
    }
}

/// The little preview bubble shown above a pressed letter key (system-keyboard
/// style). Purely decorative.
final class KeyPopupView: UIView {
    private let label = UILabel()

    init(text: String, metrics: KeyboardTheme.Metrics) {
        super.init(frame: .zero)
        backgroundColor = KeyboardTheme.popupFill
        layer.cornerRadius = metrics.keyCornerRadius + 2
        layer.cornerCurve = .continuous
        layer.shadowColor = KeyboardTheme.keyShadow.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 2
        layer.shadowOpacity = 0.6
        isUserInteractionEnabled = false

        label.text = text
        label.textAlignment = .center
        label.textColor = KeyboardTheme.keyText
        label.font = .systemFont(ofSize: metrics.letterFontSize + 6)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }
}
