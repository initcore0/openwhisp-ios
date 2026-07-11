import UIKit

/// The keyboard extension's principal view controller.
///
/// WP1 renders a minimal placeholder row that proves the extension loads and can
/// insert text (the globe key is required for input-mode switching). The real
/// hand-rolled keyboard — layout pages, shift/autocap, the mic key resolved by
/// `MicKeyResolver` — lands in WP4, driven by `KeyboardLayoutModel` in KeyboardCore.
final class KeyboardViewController: UIInputViewController {

    private lazy var nextKeyboardButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()

        let label = UILabel()
        label.text = "OpenWhisp keyboard (scaffold)"
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        // A trivial insert button proves the proxy works end-to-end.
        let insertButton = UIButton(type: .system)
        insertButton.setTitle("Insert “hi”", for: .normal)
        insertButton.addTarget(self, action: #selector(insertSample), for: .touchUpInside)
        insertButton.translatesAutoresizingMaskIntoConstraints = false

        // The globe key is required so the user can switch keyboards (4.4.1).
        nextKeyboardButton.setTitle("🌐", for: .normal)
        nextKeyboardButton.addTarget(self,
                                     action: #selector(handleInputModeList(from:with:)),
                                     for: .allTouchEvents)
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [nextKeyboardButton, label, insertButton])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func insertSample() {
        textDocumentProxy.insertText("hi")
    }
}
