import UIKit
import KeyboardCore
import MobileCore

/// The keyboard extension's principal view controller.
///
/// It is the thin UIKit shell over KeyboardCore: it owns the `KeyboardLayoutModel`,
/// the `ProxyTextSink`, the live `HandoffEnvironment`, and the `KeyboardView`, and
/// it turns the view's high-level events into model mutations + proxy writes. Every
/// *decision* is delegated to the tested core:
///   - what a key emits → `KeyboardLayoutModel.apply`
///   - autocap re-arm → `KeyboardLayoutModel.updateAutocap`
///   - what the mic key means → `MicKeyResolver.resolve`
///   - inserting a pending transcript → `TranscriptInserter` (+ `TranscriptInsertPolicy`)
///   - double-tap space/shift, backspace cadence → `KeyboardGesture` / `BackspaceRepeatCadence`
///
/// Typing NEVER gates on Full Access, the App Group, or any dictation state — the
/// keyboard is a fully functional plain keyboard with Full Access off (4.4.1 / C8).
final class KeyboardViewController: UIInputViewController, KeyboardViewDelegate {

    // MARK: - Core state

    private var model = KeyboardLayoutModel(page: .letters, shift: .on, autocapEnabled: true)
    private lazy var sink = ProxyTextSink(controller: self)
    private let inserter = TranscriptInserter()

    /// The live handoff pieces (App Group). nil when Full Access is off / the
    /// entitlement is unavailable — the mic key then shows the explainer.
    private let handoff = HandoffEnvironment.live()

    private var keyboardView: KeyboardView!

    /// Explicit height for the input host. A `UIInputViewController` has no
    /// intrinsic height, so without this the system gives the input view a minimal
    /// height and the keys collapse on top of each other. We drive it from the
    /// metrics and update it on rotation / size-class change.
    private var heightConstraint: NSLayoutConstraint?

    /// The currently-shown mic panel (explainer / capture-UX), if any.
    private var micPanel: MicPanelView?

    /// A timer that polls the shared capture state while the keyboard is visible,
    /// so the listening indicator animates and a missed Darwin ping is caught.
    private var captureStatePollTimer: Timer?
    private var isVisible = false

    /// The last mic behavior we rendered, to avoid redundant relayout churn.
    private var lastMicBehavior: MicKeyBehavior?

    // MARK: - R0b spike probe (DEBUG only, OFF by default)
    //
    // The responder-chain `openURL:` hack to open the host from a keyboard is
    // UNSUPPORTED and App-Review-risky (constraint C9). It ships in NO release
    // build: it is compiled only under DEBUG and gated behind this flag, which is
    // false by default. It exists solely so the WP2 R0b tier-4 spike
    // (docs/TESTING.md → "R0b — keyboard→host trigger") can measure whether it
    // even works on the target OS. Never flip this true in a shipping config.
    #if DEBUG
    private let enableOpenURLSpikeProbe = false
    #endif

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildKeyboard()
        wireDarwinPing()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        // Autocap re-arm against the field we're attaching to.
        applyAutocapFromContext()
        // Return-trip contract (R0c): re-resolve + auto-insert any pending transcript.
        refreshMicKey(trigger: .viewWillAppear)
        startCaptureStatePoll()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        stopCaptureStatePoll()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // The width/orientation may have changed → refresh metrics + height.
        refreshHeight()
        let metrics = KeyboardTheme.metrics(for: traitCollection)
        keyboardView?.update(model: model, returnLabel: sink.returnKeyLabel, metrics: metrics)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // The host may have changed the field (e.g. focus moved) → re-arm autocap
        // and refresh the return-key face.
        applyAutocapFromContext()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refreshHeight()
        let metrics = KeyboardTheme.metrics(for: traitCollection)
        keyboardView?.update(model: model, returnLabel: sink.returnKeyLabel, metrics: metrics)
    }

    // MARK: - Build

    private func buildKeyboard() {
        let metrics = KeyboardTheme.metrics(for: traitCollection)
        let kv = KeyboardView(
            model: model,
            returnLabel: sink.returnKeyLabel,
            showsGlobe: needsInputModeSwitchKey,
            metrics: metrics
        )
        kv.delegate = self
        kv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(kv)
        NSLayoutConstraint.activate([
            kv.topAnchor.constraint(equalTo: view.topAnchor),
            kv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            kv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            kv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        keyboardView = kv
        view.backgroundColor = KeyboardTheme.backdrop

        // Give the input host an explicit height (see `heightConstraint`). Use a
        // <required priority so UIKit's own transient input-view constraints don't
        // conflict during presentation.
        let h = view.heightAnchor.constraint(equalToConstant: desiredKeyboardHeight(for: metrics))
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h
    }

    /// The total keyboard height for a metrics set: four key rows (three letter
    /// rows + the bottom control row) plus the inter-row gaps and top/bottom insets.
    private func desiredKeyboardHeight(for metrics: KeyboardTheme.Metrics) -> CGFloat {
        let rows: CGFloat = 4
        let gaps: CGFloat = rows - 1
        return rows * metrics.rowHeight
            + gaps * metrics.rowSpacing
            + metrics.topInset
            + metrics.bottomInset
    }

    private func refreshHeight() {
        let metrics = KeyboardTheme.metrics(for: traitCollection)
        heightConstraint?.constant = desiredKeyboardHeight(for: metrics)
    }

    private func wireDarwinPing() {
        // Only meaningful with the App Group (Full Access). Best-effort — the
        // viewWillAppear read is the reliability floor.
        handoff?.notifier.onPublished = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isVisible else { return }
                self.refreshMicKey(trigger: .darwinPing)
            }
        }
    }

    // MARK: - Config

    /// The keyboard config from the shared store (autocap/haptics), defaulting to
    /// `.default` when Full Access is off (store unreadable). Autocap default is
    /// on, so typing feels right even without Full Access.
    private var config: KeyboardConfig {
        handoff?.sharedState.readKeyboardConfig() ?? .default
    }

    // MARK: - KeyboardViewDelegate

    func keyboardView(_ view: KeyboardView, didTap action: KeyAction) {
        switch action {
        case .mic:
            handleMicTap()
        case .globe:
            advanceToNextInputMode()
        default:
            applyToModel(action)
        }
    }

    func keyboardViewBackspaceRepeat(_ view: KeyboardView, wordDeletion: Bool) {
        if wordDeletion {
            deleteWordBackward()
        } else {
            sink.deleteBackward(1)
        }
        applyAutocapFromContext()
    }

    func keyboardViewDidDoubleTapSpace(_ view: KeyboardView) {
        // The first tap already inserted a space (via the model). Decide with the
        // tested gesture model what the second tap means.
        switch KeyboardGesture.spaceDoubleTap(contextBeforeCaret: sink.contextBeforeCaret) {
        case .periodSpace:
            // Turn "word " into "word. ": remove the trailing space, add ". ".
            sink.deleteBackward(1)
            sink.insert(". ")
        case .plainSpace:
            sink.insert(" ")
        }
        applyAutocapFromContext()
    }

    func keyboardViewDidDoubleTapShift(_ view: KeyboardView) {
        // Drive the model's shift to the tested double-tap result deterministically,
        // reaching it via the model's own `.shift` transitions so the caps-lock
        // indicator and casing stay consistent with the state machine.
        var m = model
        let target = KeyboardGesture.shiftAfterDoubleTap(from: m.shift)
        setShift(target, on: &m)
        model = m
        rerenderKeyFaces()
    }

    func keyboardViewPlayInputClick(_ view: KeyboardView) {
        // System input click: allowed for any keyboard; the *haptic* (below) needs
        // Full Access. `enableInputClicksWhenVisible` + `playInputClick` is the
        // sanctioned path.
        UIDevice.current.playInputClick()
        #if !targetEnvironment(simulator)
        if config.haptics, hasFullAccess {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #endif
    }

    // MARK: - Applying model actions

    private func applyToModel(_ action: KeyAction) {
        let output = model.apply(action)
        switch output {
        case .text(let s):
            sink.insert(s)
            applyAutocapFromContext()
        case .deleteBackward:
            sink.deleteBackward(1)
            applyAutocapFromContext()
        case .submitReturn:
            sink.insert("\n")
            applyAutocapFromContext()
        case .switchInputMode:
            advanceToNextInputMode()
        case .micTapped:
            handleMicTap()
        case .refineLastTapped:
            break   // no refine affordance in v1
        case .none:
            // Shift / page toggle changed the model but emit nothing.
            rerenderKeyFaces()
        }
    }

    /// Re-arm autocap from the live caret context and re-render the letter faces.
    private func applyAutocapFromContext() {
        model.autocapEnabled = config.autocap
        model.updateAutocap(contextBeforeCaret: sink.contextBeforeCaret)
        rerenderKeyFaces()
    }

    private func rerenderKeyFaces() {
        let metrics = KeyboardTheme.metrics(for: traitCollection)
        keyboardView?.update(model: model, returnLabel: sink.returnKeyLabel, metrics: metrics)
    }

    /// Advance the model's shift to `target` using its `.shift` transitions so the
    /// caps-lock indicator and casing stay consistent with the state machine.
    private func setShift(_ target: ShiftState, on m: inout KeyboardLayoutModel) {
        var guardCount = 0
        while m.shift != target && guardCount < 4 {
            _ = m.apply(.shift)
            guardCount += 1
        }
    }

    /// Word-granularity backspace: delete the trailing run of whitespace, then the
    /// trailing run of word characters (approximating iOS's held-backspace behavior).
    private func deleteWordBackward() {
        guard let context = sink.contextBeforeCaret, !context.isEmpty else { return }
        var toDelete = 0
        let chars = Array(context)
        var i = chars.count - 1
        while i >= 0, chars[i].isWhitespace { toDelete += 1; i -= 1 }
        while i >= 0, !chars[i].isWhitespace { toDelete += 1; i -= 1 }
        sink.deleteBackward(max(1, toDelete))
    }

    // MARK: - Mic key

    private func handleMicTap() {
        refreshMicKey(trigger: .micTap)
    }

    /// Re-resolve the mic key against the live handoff state and act per the
    /// trigger (auto-insert on return-trip triggers, state-only on a poll).
    private func refreshMicKey(trigger: MicKeyRefreshTrigger) {
        let fullAccess = hasFullAccess
        let captureState = handoff?.sharedState.readCaptureState() ?? .idle
        // `try?` on an optional chain gives `PendingTranscript??`; flatten it.
        let pending: PendingTranscript? = (try? handoff?.store.peek()).flatMap { $0 }

        let behavior = MicKeyResolver.resolve(
            fullAccess: fullAccess,
            captureState: captureState,
            pending: pending,
            now: Date()
        )

        // Update the mic-key visual (listening pulse when capturing, accent when a
        // transcript is ready to drop).
        renderMicKeyState(behavior)

        switch behavior {
        case .explainFullAccess:
            if trigger == .micTap { showPanel(.fullAccess) }
        case .showCaptureUX:
            if trigger == .micTap {
                showPanel(.captureUX)
                #if DEBUG
                if enableOpenURLSpikeProbe { openHostViaResponderChainSpike() }
                #endif
            }
        case .showCapturing:
            // Nothing to insert yet — the poll animates the indicator.
            if trigger == .micTap { dismissPanel() }
        case .insertPending(let id):
            // Auto-insert on return-trip triggers and on an explicit tap; a poll
            // tick must not (it would double-insert as state settles).
            if trigger.performsAutoInsert {
                performInsert(id: id)
            }
        }
        lastMicBehavior = behavior
    }

    private func performInsert(id: UUID) {
        guard let store = handoff?.store else { return }
        dismissPanel()
        let outcome = try? inserter.insert(id: id, from: store, into: sink, now: Date())
        if case .inserted = outcome {
            applyAutocapFromContext()
        }
        // After a consume the mailbox is empty → refresh the key to its idle look.
        renderMicKeyState(.showCaptureUX)
    }

    private func renderMicKeyState(_ behavior: MicKeyBehavior) {
        switch behavior {
        case .showCapturing:
            keyboardView?.styleMicKey(latched: true, accent: true)
            startMicPulse()
        case .insertPending:
            stopMicPulse()
            keyboardView?.styleMicKey(latched: true, accent: true)
        case .showCaptureUX, .explainFullAccess:
            stopMicPulse()
            keyboardView?.styleMicKey(latched: false, accent: false)
        }
    }

    // MARK: - Mic listening pulse

    private var micPulseTimer: Timer?
    private var micPulseOn = false

    private func startMicPulse() {
        guard micPulseTimer == nil else { return }
        micPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, let mic = self.keyboardView?.micKey else { return }
            self.micPulseOn.toggle()
            UIView.animate(withDuration: 0.3) {
                mic.alpha = self.micPulseOn ? 0.5 : 1.0
            }
        }
    }

    private func stopMicPulse() {
        micPulseTimer?.invalidate()
        micPulseTimer = nil
        keyboardView?.micKey?.alpha = 1.0
    }

    // MARK: - Capture-state poll

    private func startCaptureStatePoll() {
        guard handoff != nil, captureStatePollTimer == nil else { return }
        captureStatePollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.refreshMicKey(trigger: .captureStatePoll)
        }
    }

    private func stopCaptureStatePoll() {
        captureStatePollTimer?.invalidate()
        captureStatePollTimer = nil
        stopMicPulse()
    }

    // MARK: - Panels

    private func showPanel(_ style: MicPanelView.Style) {
        dismissPanel()
        let panel = MicPanelView(style: style)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onDismiss = { [weak self] in self?.dismissPanel() }
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            panel.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
        ])
        micPanel = panel
    }

    private func dismissPanel() {
        micPanel?.removeFromSuperview()
        micPanel = nil
    }

    // MARK: - R0b openURL spike (DEBUG only)

    #if DEBUG
    /// UNSUPPORTED responder-chain `openURL:` — probe ONLY. See the flag comment.
    private func openHostViaResponderChainSpike() {
        guard let url = URL(string: "openwhisp://dictate") else { return }
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                _ = r.perform(selector, with: url)
                break
            }
            responder = r.next
        }
    }
    #endif
}
