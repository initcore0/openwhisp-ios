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
        backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 0.98)
                : UIColor(white: 0.97, alpha: 0.98)
        }
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor

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
            bodyLabel.text = "Full Access lets the keyboard read the finished transcript OpenWhisp made in the app. That's all it unlocks — no logging, no network except syncing to your own Mac. Typing works fully without it."
        case .captureUX:
            titleLabel.text = "Dictate in the OpenWhisp app"
            bodyLabel.text = "Dictation runs in the OpenWhisp app — open OpenWhisp (or use your Action button) and speak; the text lands here when you come back."
        }

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .tertiaryLabel
        closeButton.addTarget(self, action: #selector(dismiss), for: .touchUpInside)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 3

        let row = UIStackView(arrangedSubviews: [icon, textStack, closeButton])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
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
