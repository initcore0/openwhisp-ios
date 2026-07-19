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

    /// The live SESSION pieces (App Group): command mailbox (keyboard→host), the
    /// live-partial store (host→keyboard), and the status reader. nil when the App
    /// Group is unavailable — session features then stay invisible and the mic key
    /// is exactly today's floor flow (WP10c, §6.8, [C2][C8]).
    private let session = SessionEnvironment.live()

    /// Pure model that turns each incoming `LivePartial` into a minimal proxy edit,
    /// tracking only the last-rendered string per capture (§6.8, D12).
    private var partialRender = LivePartialRenderModel()

    /// Darwin wake-ups for the session partial/status streams (best-effort; the
    /// polls are the reliability floor). Retained so the observers stay alive.
    private var partialObserver: SessionDarwinObserver?
    private var statusObserver: SessionDarwinObserver?

    /// The 250 ms partial poll, running ONLY while the session is capturing and we
    /// are actively rendering live (never on the typing hot path).
    private var partialPollTimer: Timer?

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
        refreshConfigCache()
        buildKeyboard()
        wireDarwinPing()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        // Pick up any config the host changed while we were away (cheap, once).
        refreshConfigCache()
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
        stopLivePartialLoop()
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
                // The host may have republished config alongside the transcript.
                self.refreshConfigCache()
                self.refreshMicKey(trigger: .darwinPing)
            }
        }

        // Session status changes → re-resolve the mic key promptly (arm/disarm,
        // capture start/stop). The poll catches missed pings.
        if session != nil {
            let statusObs = SessionDarwinObserver(name: SessionDarwinNames.status)
            statusObs.onNotify = { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.isVisible else { return }
                    self.refreshMicKey(trigger: .darwinPing)
                }
            }
            statusObserver = statusObs

            // Live partials → render immediately (the 250 ms poll is the floor).
            let partialObs = SessionDarwinObserver(name: SessionDarwinNames.partial)
            partialObs.onNotify = { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.isVisible else { return }
                    self.pumpLivePartial()
                }
            }
            partialObserver = partialObs
        }
    }

    // MARK: - Config

    /// A CACHED snapshot of the keyboard config from the shared store
    /// (autocap/haptics). Reading it hits the disk (a JSON file read + decode); doing
    /// that on every keystroke — as the old computed property did via
    /// `applyAutocapFromContext` — is needless per-keypress I/O. The host publishes
    /// config changes through the App Group, so we refresh the cache only when the
    /// keyboard (re)appears and when a Darwin ping tells us something changed.
    /// Defaults to `.default` when Full Access is off (store unreadable): autocap on,
    /// so typing feels right even without Full Access.
    private var cachedConfig: KeyboardConfig = .default
    private var config: KeyboardConfig { cachedConfig }

    /// Re-read the shared config from disk into the cache. Call sparingly — on
    /// (re)appearance and on a Darwin ping, NOT per keystroke.
    private func refreshConfigCache() {
        cachedConfig = handoff?.sharedState.readKeyboardConfig() ?? .default
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
        dismissPanel()
        if wordDeletion {
            deleteWordBackward()
        } else {
            sink.deleteBackward(1)
        }
        applyAutocapFromContext()
    }

    func keyboardViewDidDoubleTapSpace(_ view: KeyboardView) {
        dismissPanel()
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
        dismissPanel()
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
            dismissPanel()   // any typing dismisses a raised mic panel (its doc contract)
            sink.insert(s)
            applyAutocapFromContext()
        case .deleteBackward:
            dismissPanel()
            sink.deleteBackward(1)
            applyAutocapFromContext()
        case .submitReturn:
            dismissPanel()
            sink.insert("\n")
            applyAutocapFromContext()
        case .switchInputMode:
            advanceToNextInputMode()
        case .micTapped:
            handleMicTap()
        case .refineLastTapped:
            break   // no refine affordance in v1
        case .none:
            // Shift / page toggle changed the model but emit nothing. These are
            // still key presses, so a raised mic panel dismisses (it must never
            // hover over the top rows once the user starts interacting — its doc
            // contract is "dismiss on the next key").
            dismissPanel()
            rerenderKeyFaces()
        }
    }

    /// Re-arm autocap from the live caret context and re-render the letter faces.
    /// Sentence autocap is enabled only when BOTH the user config allows it AND the
    /// host field hasn't opted out (`autocapitalizationType == .none`, e.g. a
    /// username/URL field) — matching the system keyboard, which never leading-caps
    /// a `.none` field.
    private func applyAutocapFromContext() {
        model.autocapEnabled = config.autocap && (sink.autocapType != .none)
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

    /// Re-resolve the mic key and act per the trigger. When a session env exists
    /// (App Group available), resolve the SESSION-aware behavior (§6.8, D11): an
    /// armed session turns the key into a live capture remote; no live session
    /// falls back to EXACTLY today's floor flow. Without the App Group, session
    /// features are invisible and we go straight to the floor flow ([C2][C8]).
    private func refreshMicKey(trigger: MicKeyRefreshTrigger) {
        guard let session else {
            refreshFloorMicKey(trigger: trigger)
            return
        }

        let fullAccess = hasFullAccess
        let now = Date()
        let status = session.statusReader.read(now: now)
        let captureState = handoff?.sharedState.readCaptureState() ?? .idle
        let pending: PendingTranscript? = (try? handoff?.store.peek()).flatMap { $0 }

        let behavior = MicKeyResolver.resolveSession(
            fullAccess: fullAccess,
            sessionStatus: status,
            captureState: captureState,
            pending: pending,
            now: now
        )

        switch behavior {
        case .explainFullAccess:
            stopLivePartialLoop()
            renderMicKeyState(.explainFullAccess)
            if trigger == .micTap { showPanel(.fullAccess) }
        case .startCapture:
            // Armed & idle: the key latches (accent) to invite a tap; a tap posts
            // startCapture. No live rendering yet.
            stopLivePartialLoop()
            keyboardView?.styleMicKey(latched: true, accent: true)
            stopMicPulse()
            if trigger == .micTap {
                dismissPanel()
                postSessionCommand(.startCapture, now: now)
            }
        case .stopCapture:
            // Capturing: pulse the key and run the live-partial loop. A tap posts
            // stopCapture (the host finalizes; the final swaps in via the loop).
            renderMicKeyState(.showCapturing)  // latched + pulse
            startLivePartialLoop()
            if trigger == .micTap {
                dismissPanel()
                postSessionCommand(.stopCapture, now: now)
            }
        case .showTranscribing:
            // The final is wrapping up — keep the pulse, keep draining partials so
            // the final swap lands, but a tap starts nothing new.
            renderMicKeyState(.showCapturing)
            startLivePartialLoop()
            if trigger == .micTap { dismissPanel() }
        case .startSessionHop(let floor):
            // No live session → exactly today's floor flow, unchanged.
            stopLivePartialLoop()
            actOnFloorBehavior(floor, trigger: trigger)
        }
    }

    /// The pre-session mic-key path, preserved verbatim: used when the App Group is
    /// unavailable (no session env at all).
    private func refreshFloorMicKey(trigger: MicKeyRefreshTrigger) {
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
        actOnFloorBehavior(behavior, trigger: trigger)
    }

    /// Render + act on a floor-flow `MicKeyBehavior` (shared by the no-App-Group
    /// path and the `.startSessionHop` case). Identical semantics to the original
    /// `refreshMicKey`.
    private func actOnFloorBehavior(_ behavior: MicKeyBehavior, trigger: MicKeyRefreshTrigger) {
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

    // MARK: - Session commands + live-partial loop (§6.8, D12)

    /// Post a session command to the mailbox and ping the host. Off the typing hot
    /// path — only fired from an explicit mic tap.
    private func postSessionCommand(_ cmd: SessionCommand, now: Date) {
        guard let session else { return }
        try? session.commandMailbox.post(cmd, now: now)
        // A best-effort Darwin ping wakes the host; the mailbox is the truth.
        SessionDarwinObserver(name: SessionDarwinNames.command).post()
    }

    /// Start the 250 ms partial poll (idempotent). Runs only while capturing.
    private func startLivePartialLoop() {
        guard session != nil, partialPollTimer == nil else { return }
        // Drain whatever is already there right away.
        pumpLivePartial()
        partialPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.pumpLivePartial()
        }
    }

    private func stopLivePartialLoop() {
        partialPollTimer?.invalidate()
        partialPollTimer = nil
        partialRender.reset()
    }

    /// Read the latest `LivePartial` and render it through the pure model. NEVER
    /// renders into a secure field — the model's suppression is decided before any
    /// edit, and the final falls back to the WP5 pending-transcript path there.
    private func pumpLivePartial() {
        guard let session,
              let partial = (try? session.partialStore.read()).flatMap({ $0 }) else { return }

        let decision = partialRender.apply(partial, isSecureField: sink.isSecureField)
        switch decision {
        case .ignore:
            break
        case .edit(let deleteBackward, let insert):
            if deleteBackward > 0 { sink.deleteBackward(deleteBackward) }
            if !insert.isEmpty { sink.insert(insert) }
            if partial.isFinal {
                // The final settled this capture; re-arm autocap against the new caret.
                applyAutocapFromContext()
                // The live final IS the insertion for this capture — retire the WP5
                // pending transcript (its id rides the final as `pendingID`, §6.8)
                // so the floor flow can't insert a second copy once the session
                // disarms. Suppressed (secure-field) captures never reach this
                // branch and keep their pending for the WP5 path.
                if let pendingID = partial.pendingID {
                    _ = try? handoff?.store.consume(id: pendingID, now: Date())
                }
            }
        }
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
            // Latched (lit) but NOT accented — the pulse animation carries the
            // "listening…" signal; the accent tint is reserved for "ready to drop".
            keyboardView?.styleMicKey(latched: true, accent: false)
            startMicPulse()
        case .insertPending:
            // Latched AND accented, steady (no pulse): a transcript is ready to insert.
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
        guard handoff != nil || session != nil, captureStatePollTimer == nil else { return }
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
        // Cover the WHOLE keyboard. Top-pinning only let the panel float over the
        // upper key rows at its intrinsic height — keys poked out beneath it and
        // the whole thing read as a rendering glitch, not a message.
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.topAnchor.constraint(equalTo: view.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
