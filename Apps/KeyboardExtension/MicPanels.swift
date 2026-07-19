import UIKit

/// The inline panels the mic key raises above the keyboard. They are compact,
/// never modal, and never block typing (constraint C8 / guideline 4.4.1): the
/// keyboard keeps working behind/around them and they dismiss on the next key.
///
/// Copy tone follows ARCHITECTURE §7's Full-Access story: plain language, says
/// what Full Access unlocks and what we never do.
final class MicPanelView: UIView {

    /// A dismiss handle the controller wires to "hide me".
    var onDismiss: (() -> Void)?

    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    enum Style { case fullAccess, captureUX }

    init(style: Style) {
        super.init(frame: .zero)
        // Fully OPAQUE and edge-to-edge: the panel now covers the whole keyboard
        // (see showPanel), so any translucency/corner-radius would show key caps
        // bleeding through and read as a glitch.
        backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.12, alpha: 1.0)
                : UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1.0)
        }

        let icon = UIImageView(image: UIImage(systemName: style == .fullAccess ? "lock.shield" : "mic.circle"))
        icon.tintColor = KeyboardTheme.accent
        icon.contentMode = .center
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).bold()
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1

        bodyLabel.font = .preferredFont(forTextStyle: .footnote)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        switch style {
        case .fullAccess:
            titleLabel.text = "Turn on Full Access for dictation"
            bodyLabel.text = "iOS Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards \u{2192} OpenWhisp \u{2192} Allow Full Access. It lets the keyboard read the finished transcript OpenWhisp made in the app — no logging, no network except syncing to your own Mac. Typing works fully without it."
        case .captureUX:
            titleLabel.text = "Dictate in the OpenWhisp app"
            bodyLabel.text = "Dictation runs in the OpenWhisp app — open OpenWhisp (or use your Action button) and speak; the text lands here when you come back."
        }

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.addTarget(self, action: #selector(dismiss), for: .touchUpInside)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        // The panel covers the whole keyboard, so a tap ANYWHERE dismisses it and
        // returns to typing — the close button must never be the only way out
        // (typing never blocks on dictation surfaces, constraint C8).
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismiss)))

        let textStack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        let row = UIStackView(arrangedSubviews: [icon, textStack, closeButton])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // Top-aligned content in a full-cover panel: pinning the bottom too would
        // stretch the text block across the whole keyboard height.
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            icon.widthAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func dismiss() { onDismiss?() }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let d = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: d, size: pointSize)
    }
}
