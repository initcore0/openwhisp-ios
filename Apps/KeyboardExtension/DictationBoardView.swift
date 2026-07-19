import UIKit

/// The DICTATION BOARD: the keyboard's mic surface, replacing the old floating
/// panels. It covers the whole keyboard with one big record button + a status
/// line, so dictation is a single obvious control ("press → listen, words
/// appear, press again → the text lands"). The small ABC key returns to typing
/// — the full keyboard is always one tap away (constraint C8 / 4.4.1).
///
/// The board is dumb rendering: the controller maps the live mic-key behavior
/// (session armed / capturing / setup needed) into a `BoardState` and calls
/// `render`; taps report back through the two closures.
final class DictationBoardView: UIView {

    enum BoardState: Equatable {
        /// Session armed, idle — tapping starts listening instantly.
        case ready
        /// Host is capturing; live words are inserting at the caret.
        case listening
        /// Host is finishing the transcript (final cleanup on its way).
        case transcribing
        /// A finished transcript is waiting — tapping inserts it.
        case readyToInsert
        /// No armed session: the mic lives in the app, one-time hop needed.
        case needsSession
        /// Full Access is off: the keyboard can't read transcripts at all.
        case needsFullAccess
    }

    var onMicTap: (() -> Void)?
    var onShowKeys: (() -> Void)?

    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let micButton = UIButton(type: .custom)
    private let keysButton = UIButton(type: .system)
    private var pulse: CABasicAnimation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KeyboardTheme.backdrop

        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1

        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0

        micButton.layer.cornerRadius = 36
        micButton.layer.cornerCurve = .continuous
        micButton.tintColor = .white
        micButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 28, weight: .medium), forImageIn: .normal)
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        micButton.accessibilityIdentifier = "board.mic"

        keysButton.setTitle("ABC", for: .normal)
        keysButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline).weighted(.semibold)
        keysButton.setTitleColor(.label, for: .normal)
        keysButton.backgroundColor = KeyboardTheme.controlKey
        keysButton.layer.cornerRadius = 8
        keysButton.layer.cornerCurve = .continuous
        keysButton.addTarget(self, action: #selector(keysTapped), for: .touchUpInside)
        keysButton.accessibilityLabel = "Show keyboard"
        keysButton.accessibilityIdentifier = "board.keys"

        for v in [statusLabel, hintLabel, micButton, keysButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            micButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            micButton.topAnchor.constraint(greaterThanOrEqualTo: hintLabel.bottomAnchor, constant: 10),
            micButton.widthAnchor.constraint(equalToConstant: 72),
            micButton.heightAnchor.constraint(equalToConstant: 72),
            micButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -44),

            keysButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            keysButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            keysButton.widthAnchor.constraint(equalToConstant: 58),
            keysButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func render(_ state: BoardState) {
        switch state {
        case .ready:
            statusLabel.text = "Tap to dictate"
            hintLabel.text = "Words appear as you speak. Tap again to finish."
            setMic(symbol: "mic.fill", color: KeyboardTheme.accent, enabled: true, pulsing: false)
        case .listening:
            statusLabel.text = "Listening…"
            hintLabel.text = "Tap to finish and insert the text."
            setMic(symbol: "stop.fill", color: .systemRed, enabled: true, pulsing: true)
        case .transcribing:
            statusLabel.text = "Finishing…"
            hintLabel.text = "Cleaning up your text."
            setMic(symbol: "ellipsis", color: .systemGray, enabled: false, pulsing: true)
        case .readyToInsert:
            statusLabel.text = "Text ready"
            hintLabel.text = "Tap to insert your dictation here."
            setMic(symbol: "arrow.down.circle.fill", color: .systemGreen, enabled: true, pulsing: false)
        case .needsSession:
            statusLabel.text = "Turn the mic on in OpenWhisp"
            hintLabel.text = "iOS only lets the OpenWhisp app use the microphone. Open "
                + "OpenWhisp once and start a dictation session — then this button "
                + "listens instantly for the whole session."
            setMic(symbol: "mic.slash.fill", color: .systemGray2, enabled: false, pulsing: false)
        case .needsFullAccess:
            statusLabel.text = "Turn on Full Access"
            hintLabel.text = "iOS Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards \u{2192} "
                + "OpenWhisp \u{2192} Allow Full Access. It only lets the keyboard receive "
                + "the transcript — no logging, nothing leaves your devices."
            setMic(symbol: "lock.fill", color: .systemGray2, enabled: false, pulsing: false)
        }
    }

    private func setMic(symbol: String, color: UIColor, enabled: Bool, pulsing: Bool) {
        micButton.setImage(UIImage(systemName: symbol), for: .normal)
        micButton.backgroundColor = color
        micButton.isEnabled = enabled
        micButton.accessibilityLabel = statusLabel.text
        if pulsing, pulse == nil {
            let anim = CABasicAnimation(keyPath: "transform.scale")
            anim.fromValue = 1.0
            anim.toValue = 1.08
            anim.duration = 0.6
            anim.autoreverses = true
            anim.repeatCount = .infinity
            micButton.layer.add(anim, forKey: "pulse")
            pulse = anim
        } else if !pulsing {
            micButton.layer.removeAnimation(forKey: "pulse")
            pulse = nil
        }
    }

    @objc private func micTapped() { onMicTap?() }
    @objc private func keysTapped() { onShowKeys?() }
}

private extension UIFont {
    func weighted(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
