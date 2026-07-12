import AppIntents
import Foundation
import MobileCore

// MARK: - App Intents (the iOS-18 hero trigger) — ARCHITECTURE §5.1
//
// These are the sanctioned no-app-switch trigger [C10/C11]: the Action button /
// Control Center / Shortcuts invoke `StartDictationIntent`, which conforms to
// `AudioRecordingIntent` so iOS 18 permits it to start audio capture WITHOUT
// foregrounding the app. `StopDictationIntent` (from the Live Activity's stop
// button, or Shortcuts) ends it.
//
// This file is compiled into BOTH the host app and the widgets extension so the
// Live Activity button and the Control Center control can reference the intent
// types. The ACTUAL capture is performed in the host process via
// `IntentDictationBridge`, which the host app implements; in the widget process the
// bridge's `perform`-side work is a no-op shim (the widget never runs capture).
//
// R0a REALITY: whether a background/not-running app can actually START AVAudioEngine
// from this intent is the unverified real-device unknown (docs/TESTING.md tier-4).
//
// The graceful-degradation contract is DELIBERATELY split by what iOS 18 permits:
//   - `AudioRecordingIntent` runs WITHOUT foregrounding — that is the whole point of
//     the hero flow — so `openAppWhenRun` is false (true would foreground on every
//     run and defeat the no-app-switch trigger).
//   - When the host process is reachable (app running/foreground, or a Shortcut run
//     from within the app), a failed in-process start opens the dictation sheet via
//     the bridge's open-app handler.
//   - When the intent runs where the host is NOT reachable (widget process, or the
//     app not running) AND a background start isn't permitted, there is no iOS-18
//     API to conditionally foreground from inside `perform()`
//     (`needsToContinueInForegroundError` is iOS 26+). That exact cell is the R0a
//     device unknown: if background start fails there, the user must open OpenWhisp
//     to dictate. The Settings walkthrough sets expectations accordingly.

/// Starts a dictation capture. `AudioRecordingIntent` is the iOS-18 conformance
/// that lets this run audio capture without foregrounding the app (subject to the
/// R0a device caveat above).
@available(iOS 18.0, *)
struct StartDictationIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Start OpenWhisp Dictation"
    static var description = IntentDescription(
        "Start dictating. Speak, and OpenWhisp transcribes on-device and hands the text to your keyboard."
    )

    // Do NOT open the app on every run — the hero flow's whole value is starting
    // capture WITHOUT switching apps. See the file header for the degradation path.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let started = await IntentDictationBridge.shared.begin()
        if started {
            return .result()
        }
        // In-process capture could not start. If the host app is reachable in THIS
        // process, present the dictation sheet so the foreground path takes over.
        // If it is not reachable (widget / app-not-running), there is no iOS-18 way
        // to foreground from here — this is the R0a cell the device pass measures.
        if IntentDictationBridge.shared.canOpenAppInProcess {
            await IntentDictationBridge.shared.requestOpenApp()
        }
        return .result()
    }
}

/// Stops the in-flight dictation capture (still transcribes + publishes). Fired by
/// the Live Activity's Stop button and available in Shortcuts.
///
/// MUST conform to `LiveActivityIntent`, not plain `AppIntent`. The Stop button
/// lives in the WIDGET EXTENSION's Live Activity UI (`Button(intent:)`). A plain
/// `AppIntent` fired from there runs `perform()` in the WIDGET process, where
/// `IntentDictationBridge` has no handlers installed (only the host app installs
/// them) — so stop would be a silent no-op. `LiveActivityIntent` is the sanctioned
/// conformance that makes the system run `perform()` in the APP's process, where the
/// bridge's `stopHandler` reaches the live `IntentCaptureController`. (This mirrors
/// why `StartDictationIntent` is an `AudioRecordingIntent` — that protocol likewise
/// runs in the app process so it can drive `AVAudioEngine`.)
@available(iOS 18.0, *)
struct StopDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop OpenWhisp Dictation"
    static var description = IntentDescription("Stop the current dictation and insert the text.")

    // Not an app-launch intent: it acts on the live capture in the host process.
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentDictationBridge.shared.stop()
        return .result()
    }
}

/// The seam between the (process-agnostic) intents and the host app's capture
/// pipeline. The host app installs a real implementation on launch; in any process
/// where no implementation is installed (the widget extension), the calls are safe
/// no-ops that report "could not start" so the intent degrades to opening the app.
@MainActor
final class IntentDictationBridge {
    static let shared = IntentDictationBridge()
    private init() {}

    /// Installed by the host app on launch. Returns true iff capture actually began
    /// in this process.
    var beginHandler: (() async -> Bool)?
    /// Installed by the host app; stops the live capture.
    var stopHandler: (() async -> Void)?
    /// Installed by the host app; ROUTES the dictation sheet to be presented (sets
    /// the `DictationRouter`'s pending sheet). It does NOT — and cannot — foreground
    /// the app: a non-`openAppWhenRun` intent (this is one, deliberately, so the hero
    /// flow doesn't app-switch) has no API to bring the app to the front from inside
    /// `perform()`. So this only helps when the app is ALREADY foreground (e.g. a
    /// Shortcut the user runs from within OpenWhisp): the sheet then appears on
    /// screen. If the app is backgrounded, the sheet is queued but stays invisible
    /// until the user opens OpenWhisp themselves — which is the R0a degradation the
    /// tier-4 checklist measures, and why the hero copy warns the user accordingly.
    var openAppHandler: (() async -> Void)?

    /// Whether the app is reachable in THIS process to present the sheet (its
    /// open-app handler is installed). False in the widget process, or before the
    /// host app has launched — in which case the intent must continue in the
    /// foreground to launch the app first.
    var canOpenAppInProcess: Bool { openAppHandler != nil }

    func begin() async -> Bool {
        guard let beginHandler else { return false }
        return await beginHandler()
    }

    func stop() async {
        await stopHandler?()
    }

    func requestOpenApp() async {
        await openAppHandler?()
    }
}
