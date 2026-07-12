import UIKit
import KeyboardCore

/// The keyboard's rendering + touch surface. It is deliberately dumb: it lays out
/// caps from the current `KeyboardLayoutModel.currentRows()` plus a fixed control
/// row, tracks a single touch, and reports high-level events to its delegate. All
/// *decisions* (what a tap emits, shift cycling, autocap, double-tap meaning) are
/// made by the delegate against KeyboardCore — never here.
protocol KeyboardViewDelegate: AnyObject {
    /// A key was tapped (released inside its bounds). Backspace and shift come
    /// through here too; the delegate applies them to the model.
    func keyboardView(_ view: KeyboardView, didTap action: KeyAction)
    /// Backspace is being held: fire one deletion now (the view drives the
    /// accelerating cadence and calls this on each tick).
    func keyboardViewBackspaceRepeat(_ view: KeyboardView, wordDeletion: Bool)
    /// The space bar was double-tapped within the gesture window.
    func keyboardViewDidDoubleTapSpace(_ view: KeyboardView)
    /// The shift key was double-tapped within the gesture window.
    func keyboardViewDidDoubleTapShift(_ view: KeyboardView)
    /// Play the input click (respecting Full Access + config).
    func keyboardViewPlayInputClick(_ view: KeyboardView)
}

final class KeyboardView: UIView {

    weak var delegate: KeyboardViewDelegate?

    /// The current model state the view renders from (set by the controller).
    private(set) var model: KeyboardLayoutModel
    /// The label the return key should show (from the sink).
    private var returnLabel: ReturnKeyLabel
    /// Whether the globe key is shown (respect `needsInputModeSwitchKey`).
    private let showsGlobe: Bool

    private var metrics: KeyboardTheme.Metrics

    /// All laid-out caps, so hit-testing and appearance updates are O(keys).
    private var keys: [KeyButton] = []
    private var rowStacks: [UIStackView] = []
    private let rootStack = UIStackView()

    // Touch tracking (single active touch — the system keyboard is single-touch
    // for typing; multitouch shift+letter is a nicety we intentionally skip in v1).
    private weak var pressedKey: KeyButton?

    // Backspace repeat. The tap-vs-repeat bookkeeping lives in the tested
    // `BackspaceHold` core model: it keeps the live cadence counter separate from
    // the fired-repeats tally so a slide-off can't make a release look like a plain
    // tap (MINOR: slide-off fires one extra backspace).
    private let cadence = BackspaceRepeatCadence.system
    private var backspaceTimer: Timer?
    private var backspaceHold = BackspaceHold()

    // Double-tap timing per control key.
    private var lastSpaceTapTime: TimeInterval = 0
    private var lastShiftTapTime: TimeInterval = 0

    /// The mic key, kept referenced so the controller can drive its listening
    /// animation and accent without a full relayout.
    private(set) weak var micKey: KeyButton?

    init(model: KeyboardLayoutModel, returnLabel: ReturnKeyLabel, showsGlobe: Bool, metrics: KeyboardTheme.Metrics) {
        self.model = model
        self.returnLabel = returnLabel
        self.showsGlobe = showsGlobe
        self.metrics = metrics
        super.init(frame: .zero)
        backgroundColor = KeyboardTheme.backdrop
        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - Re-rendering

    /// Update the rendered state. Rebuilds the whole layout only when the page
    /// changes (different keys); a pure shift change just recases the letter caps
    /// and refreshes the shift key face, cheaply.
    func update(model newModel: KeyboardLayoutModel, returnLabel newReturn: ReturnKeyLabel, metrics newMetrics: KeyboardTheme.Metrics) {
        let pageChanged = newModel.page != model.page
        let metricsChanged = newMetrics.rowHeight != metrics.rowHeight
        let returnChanged = newReturn != returnLabel
        model = newModel
        returnLabel = newReturn
        metrics = newMetrics
        if pageChanged || metricsChanged || returnChanged {
            buildLayout()
        } else {
            refreshFaces()
        }
    }

    /// Update only the mic key's appearance (listening pulse / accent) without a
    /// relayout.
    func styleMicKey(latched: Bool, accent: Bool) {
        guard let micKey else { return }
        micKey.micLatched = latched
        micKey.micAccent = accent
    }

    // MARK: - Layout construction

    private func buildLayout() {
        // Tear down EVERYTHING from the previous build. `rootStack.arrangedSubviews`
        // are the per-row CONTAINER views (each wrapping a row stack); removing only
        // the inner stacks leaves those containers behind, so every rebuild appended
        // 4 more and `.fillEqually` crushed the rows until the keyboard collapsed
        // (BLOCKER: page toggles shrink rows). Remove each arranged subview from the
        // stack AND its view hierarchy, and clear the width table so its
        // `ObjectIdentifier` keys don't accumulate stale entries.
        for child in rootStack.arrangedSubviews {
            rootStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        rootStack.removeFromSuperview()
        keys.removeAll()
        rowStacks.removeAll()
        widthUnits.removeAll()
        micKey = nil

        rootStack.axis = .vertical
        rootStack.alignment = .fill
        rootStack.distribution = .fillEqually
        rootStack.spacing = metrics.rowSpacing
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: metrics.topInset),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.sideInset),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.sideInset),
            rootStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -metrics.bottomInset),
        ])

        // Key ACTIONS carry the BASE (uncased) character; casing is resolved fresh
        // at emit time by `KeyboardLayoutModel.apply`. Faces are (re)titled from the
        // cased `currentRows()` in `refreshFaces()`. Never bake cased characters into
        // an action, or shift/caps-lock freeze at build time (BLOCKER: ALL CAPS).
        let baseRows = model.currentBaseRows()

        switch model.page {
        case .letters:
            addLetterPageRows(baseRows)
        case .numbers, .symbols:
            addSymbolPageRows(baseRows)
        }
        addBottomRow()

        refreshFaces()
    }

    /// The three QWERTY rows, with shift on the left of row 3 and backspace on the
    /// right of row 3, and half-key insets on row 2 (the "asdf" row).
    private func addLetterPageRows(_ rows: [[String]]) {
        // Row 1 & 2: plain letter rows (row 2 gets side padding so it's centered).
        addKeyRow(rows[0].map { letterKey($0) })
        addKeyRow(rows[1].map { letterKey($0) }, sidePadding: true)

        // Row 3: shift + letters + backspace.
        let shift = controlKey(.shift, systemImage: shiftImageName(), widthUnits: 1.5)
        let letters = rows[2].map { letterKey($0) }
        let backspace = controlKey(.backspace, systemImage: "delete.left", widthUnits: 1.5)
        addKeyRow([shift] + letters + [backspace], letterWeightForControls: true)
    }

    /// Numbers/symbols pages: two symbol rows plus a third row that swaps in the
    /// #+= / 123 toggle and backspace.
    private func addSymbolPageRows(_ rows: [[String]]) {
        addKeyRow(rows[0].map { symbolKey($0) })
        addKeyRow(rows[1].map { symbolKey($0) })

        // Third row: toggle to the OTHER symbol page + punctuation + backspace.
        let toggleTarget: LayoutPage = (model.page == .numbers) ? .symbols : .numbers
        let toggleTitle = (model.page == .numbers) ? "#+=" : "123"
        let toggle = controlKey(.page(toggleTarget), title: toggleTitle, widthUnits: 1.4)
        let punctuation = rows[2].map { symbolKey($0) }
        let backspace = controlKey(.backspace, systemImage: "delete.left", widthUnits: 1.4)
        addKeyRow([toggle] + punctuation + [backspace], letterWeightForControls: true)
    }

    /// The bottom control row: [123/ABC] [globe?] [mic] [space] [return].
    private func addBottomRow() {
        var caps: [KeyButton] = []

        let pageToggle: KeyButton
        if model.page == .letters {
            pageToggle = controlKey(.page(.numbers), title: "123", widthUnits: 1.4)
        } else {
            pageToggle = controlKey(.page(.letters), title: "ABC", widthUnits: 1.4)
        }
        caps.append(pageToggle)

        if showsGlobe {
            caps.append(controlKey(.globe, systemImage: "globe", widthUnits: 1.1))
        }

        let mic = makeKey(action: .mic, kind: .mic, title: nil, systemImage: "mic", widthUnits: 1.1)
        micKey = mic
        caps.append(mic)

        let space = makeKey(action: .space, kind: .space, title: "space", systemImage: nil, widthUnits: 4.0)
        caps.append(space)

        let ret = controlKey(.returnKey, title: returnKeyTitle(), widthUnits: 1.8)
        caps.append(ret)

        addKeyRow(caps, letterWeightForControls: true)
    }

    // MARK: - Row builders

    private func addKeyRow(_ caps: [KeyButton], sidePadding: Bool = false, letterWeightForControls: Bool = false) {
        let stack = UIStackView(arrangedSubviews: caps)
        stack.axis = .horizontal
        stack.spacing = metrics.keySpacing
        stack.alignment = .fill
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Width weighting: letter caps share equal width; control caps are sized by
        // their widthUnits relative to a letter. We express this with width
        // constraints proportional to the first letter cap found.
        let referenceLetter = caps.first(where: { $0.kind == .letter })
        for cap in caps {
            let units = widthUnits[ObjectIdentifier(cap)] ?? 1.0
            if let referenceLetter, cap !== referenceLetter {
                cap.widthAnchor.constraint(equalTo: referenceLetter.widthAnchor, multiplier: units).isActive = true
            } else if referenceLetter == nil {
                // A row of only controls (bottom row): pin proportionally to the
                // space bar or the first cap.
                if let base = caps.first, cap !== base {
                    let baseUnits = widthUnits[ObjectIdentifier(base)] ?? 1.0
                    cap.widthAnchor.constraint(equalTo: base.widthAnchor, multiplier: units / baseUnits).isActive = true
                }
            }
        }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let inset: CGFloat = sidePadding ? (metrics.rowHeight * 0.55) : 0
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
        ])

        rootStack.addArrangedSubview(container)
        rowStacks.append(stack)
        keys.append(contentsOf: caps)
    }

    // MARK: - Key factories

    private var widthUnits: [ObjectIdentifier: CGFloat] = [:]

    private func makeKey(action: KeyAction, kind: KeyButton.Kind, title: String?, systemImage: String?, widthUnits units: CGFloat) -> KeyButton {
        let key = KeyButton(action: action, kind: kind, title: title, systemImage: systemImage, metrics: metrics)
        widthUnits[ObjectIdentifier(key)] = units
        key.isAccessibilityElement = true
        key.accessibilityLabel = accessibilityLabel(for: action, title: title)
        key.accessibilityTraits = .keyboardKey
        return key
    }

    private func letterKey(_ ch: String) -> KeyButton {
        makeKey(action: .character(ch), kind: .letter, title: ch, systemImage: nil, widthUnits: 1.0)
    }

    private func symbolKey(_ ch: String) -> KeyButton {
        makeKey(action: .character(ch), kind: .letter, title: ch, systemImage: nil, widthUnits: 1.0)
    }

    private func controlKey(_ action: KeyAction, title: String? = nil, systemImage: String? = nil, widthUnits units: CGFloat) -> KeyButton {
        makeKey(action: action, kind: .control, title: title, systemImage: systemImage, widthUnits: units)
    }

    // MARK: - Faces

    /// Refresh casing + latch state without rebuilding. Only meaningful on the
    /// letters page (where shift recases the caps); on symbol pages the characters
    /// are fixed, so re-applying the same titles is a harmless no-op.
    private func refreshFaces() {
        // Titles AND accessibility labels come from the CASED rows — the single
        // source of truth for what each letter cap shows. This is what makes
        // shift/caps-lock visibly track the live model after any page round-trip:
        // the action is base, the face is re-cased here every time the model moves.
        let flat: [String] = model.currentRows().flatMap { $0 }
        var i = 0
        for key in keys where key.kind == .letter {
            guard i < flat.count else { break }
            let face = flat[i]
            key.setTitle(face)
            key.accessibilityLabel = face
            i += 1
        }

        for key in keys where key.kind == .control {
            if case .shift = key.action {
                key.isLatched = (model.shift != .off)
                key.showsCapsLockIndicator = (model.shift == .capsLock)
            }
        }
    }

    private func shiftImageName() -> String {
        switch model.shift {
        case .off: return "shift"
        case .on: return "shift.fill"
        case .capsLock: return "capslock.fill"
        }
    }

    private func returnKeyTitle() -> String {
        switch returnLabel {
        case .return: return "return"
        case .go: return "go"
        case .next: return "next"
        case .send: return "send"
        case .search: return "search"
        case .done: return "done"
        case .join: return "join"
        case .route: return "route"
        case .emergencyCall: return "SOS"
        case .continue: return "continue"
        }
    }

    private func accessibilityLabel(for action: KeyAction, title: String?) -> String {
        switch action {
        case .character(let c): return c
        case .backspace: return "Delete"
        case .shift: return "Shift"
        case .globe: return "Next keyboard"
        case .returnKey: return returnKeyTitle()
        case .space: return "space"
        case .page(let p): return p == .letters ? "Letters" : (p == .numbers ? "Numbers" : "Symbols")
        case .mic: return "Dictate"
        case .refineLast: return "Refine"
        }
    }

    // MARK: - Touch tracking

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        guard let key = hitKey(at: point) else { return }
        pressedKey = key
        key.setPressed(true)
        delegate?.keyboardViewPlayInputClick(self)

        if case .backspace = key.action {
            startBackspaceRepeat()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let pressed = pressedKey else { return }
        let point = touch.location(in: self)
        // If the finger slid off the pressed key, cancel the press (matches iOS:
        // letter keys track under the finger, but v1 keeps it simple — release
        // resolves against the key under the finger at lift, below).
        let stillInside = pressed.frame.insetBy(dx: -metrics.keySpacing, dy: -metrics.rowSpacing).contains(convert(point, to: pressed.superview))
        if !stillInside, case .backspace = pressed.action {
            // Dragging off backspace stops the repeat timer and resets the LIVE
            // counter — but preserves the fired tally, so a release after a slide-off
            // is not misread as a plain tap (MINOR 3).
            backspaceTimer?.invalidate()
            backspaceTimer = nil
            backspaceHold.slideOff()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let pressed = pressedKey else { return }
        let point = touch.location(in: self)
        pressed.setPressed(false)
        pressedKey = nil

        if case .backspace = pressed.action {
            // Ask the tested model whether this release was a plain tap. It uses the
            // fired-repeats tally (which a slide-off does NOT reset), so a hold that
            // already deleted characters never emits a spurious extra backspace.
            let plainTap = backspaceHold.releaseWasPlainTap
            stopBackspaceRepeat()
            if plainTap {
                delegate?.keyboardView(self, didTap: .backspace)
            }
            return
        }

        // Resolve the release against the key under the finger (so a small slip
        // still types the intended key).
        let releaseKey = hitKey(at: point) ?? pressed
        dispatchTap(for: releaseKey)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        pressedKey?.setPressed(false)
        pressedKey = nil
        stopBackspaceRepeat()
    }

    private func hitKey(at point: CGPoint) -> KeyButton? {
        for key in keys {
            let inSelf = key.convert(key.bounds, to: self)
            if inSelf.contains(point) { return key }
        }
        return nil
    }

    /// Turn a released key into the right delegate call, applying the double-tap
    /// gesture semantics for space and shift.
    private func dispatchTap(for key: KeyButton) {
        let nowT = ProcessInfo.processInfo.systemUptime

        switch key.action {
        case .space:
            let interval = nowT - lastSpaceTapTime
            lastSpaceTapTime = nowT
            if KeyboardGesture.isDoubleTap(interval: interval) {
                lastSpaceTapTime = 0   // consume, so a triple-tap doesn't re-fire
                delegate?.keyboardViewDidDoubleTapSpace(self)
            } else {
                delegate?.keyboardView(self, didTap: .space)
            }

        case .shift:
            let interval = nowT - lastShiftTapTime
            lastShiftTapTime = nowT
            if KeyboardGesture.isDoubleTap(interval: interval) {
                lastShiftTapTime = 0
                delegate?.keyboardViewDidDoubleTapShift(self)
            } else {
                delegate?.keyboardView(self, didTap: .shift)
            }

        default:
            delegate?.keyboardView(self, didTap: key.action)
        }
    }

    // MARK: - Backspace repeat

    private func startBackspaceRepeat() {
        backspaceHold.begin()
        scheduleNextBackspace()
    }

    private func scheduleNextBackspace() {
        let nextIndex = backspaceHold.liveRepeatCount + 1
        let delay = cadence.delay(beforeRepeat: nextIndex)
        backspaceTimer?.invalidate()
        backspaceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.backspaceHold.fireRepeat()
            let word = self.cadence.deletesWord(afterRepeats: self.backspaceHold.liveRepeatCount)
            self.delegate?.keyboardViewBackspaceRepeat(self, wordDeletion: word)
            self.scheduleNextBackspace()
        }
    }

    private func stopBackspaceRepeat() {
        backspaceTimer?.invalidate()
        backspaceTimer = nil
        backspaceHold.begin()   // fully reset for the next hold
    }
}
