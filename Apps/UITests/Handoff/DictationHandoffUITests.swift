import XCTest

/// Tier-3 (simulator XCUITest) floor-flow test (ARCHITECTURE §5.2, WP5). Drives the
/// WHOLE dictation-sheet handoff on the simulator with NO mic and NO model, using
/// the DEBUG scripted fake engine (`-openwhisp-uitest-fake-engine`):
///
///   launch with the fake engine + auto-open-dictate
///     -> the compact dictation sheet appears (waveform + "Listening…")
///     -> the scripted fake finishes after ~1s (via the real SilenceAutoStop path)
///     -> the sheet shows the "published / return to your app" state
///     -> the published transcript text is the value read BACK FROM the handoff
///        store, so asserting on it proves the durable publish, not just a UI label.
///
/// This proves the floor flow end-to-end (deep-link route -> sheet -> capture ->
/// publish -> store -> published UI) deterministically. The REAL `openwhisp://dictate`
/// URL delivery is exercised manually (scripts/run-sim.sh + the simctl openurl step
/// in the PR checklist), which cannot be made hermetic inside XCUITest.
///
/// ROBUSTNESS (was flaky, CI-red on slow runners): the published sheet used to
/// auto-dismiss 2.5s after publish, so a slow runner could miss the window between
/// "published state appears" and "sheet gone", failing the assertion. Two changes
/// make this deterministic regardless of runner speed:
///
///   1. Launch with `-openwhisp-uitest-no-autodismiss` so the published sheet STAYS
///      UP indefinitely — there is no timed window to miss.
///   2. Assert on `sheet.publishedText`, which the view model populates by reading
///      the transcript BACK from the handoff store (`store.peek()` in
///      HandoffDictationViewModel.apply(.published)). That element is the durable
///      store contents surfaced in the UI — the durable-outcome check the review
///      asked for, expressed in a way XCUITest (running inside the simulator, with
///      no shell/simctl access) can actually observe.
///
/// A `sleep(4)` inserted before the assertions still passes (proven locally per the
/// review's slowed-run probe), because nothing here races a timer.
final class DictationHandoffUITests: XCTestCase {

    /// The scripted fake engine's fixed final (mirrors `ScriptedFakeEngine`).
    private let scriptedFinalFragment = "scripted dictation for UI testing"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uitest-skip-onboarding",
            "-openwhisp-uitest-fake-engine",
            "-openwhisp-uitest-open-dictate",
            // Keep the published sheet up so the assertions never race the 2.5s
            // auto-dismiss on a slow runner (this was the CI-red flake).
            "-openwhisp-uitest-no-autodismiss",
        ]
        app.launch()
        return app
    }

    func testFloorFlowSheetPublishesScriptedTranscript() {
        let app = launchApp()
        XCTAssertEqual(app.state, .runningForeground, "app did not reach the foreground")

        // The dictation sheet is up: its status label exists.
        let status = app.staticTexts["sheet.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10),
                      "the dictation sheet never appeared for the deep-link route")

        // The scripted fake reaches the published state within a few seconds
        // (speech burst -> SilenceAutoStop -> transcribe -> publish).
        let published = app.staticTexts["sheet.published"]
        XCTAssertTrue(published.waitForExistence(timeout: 15),
                      "the sheet never reached the published/handed-off state")

        // Durable outcome: `sheet.publishedText` is the transcript READ BACK from the
        // handoff store (store.peek in the view model), so this asserts the transcript
        // was actually published to the store — not just that a label rendered. With
        // auto-dismiss disabled it stays on screen regardless of runner speed.
        let text = app.staticTexts["sheet.publishedText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5),
                      "the published transcript text (read back from the store) was not shown")
        XCTAssertTrue(
            text.label.contains(scriptedFinalFragment),
            "unexpected published/store transcript: \(text.label)"
        )

        // The sheet is still up (auto-dismiss disabled): the published state persists.
        XCTAssertTrue(published.exists,
                      "the published sheet was dismissed despite -openwhisp-uitest-no-autodismiss")
    }
}
