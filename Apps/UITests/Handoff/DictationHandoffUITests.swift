import XCTest

/// Tier-3 (simulator XCUITest) floor-flow test (ARCHITECTURE §5.2, WP5). Drives the
/// WHOLE dictation-sheet handoff on the simulator with NO mic and NO model, using
/// the DEBUG scripted fake engine (`-openwhisp-uitest-fake-engine`):
///
///   launch with the fake engine + auto-open-dictate
///     -> the compact dictation sheet appears (waveform + "Listening…")
///     -> the scripted fake finishes after ~1s (via the real SilenceAutoStop path)
///     -> the sheet shows the "published / return to your app" state
///     -> the transcript text is the scripted final.
///
/// This proves the floor flow end-to-end (deep-link route -> sheet -> capture ->
/// publish -> published UI) deterministically. The REAL `openwhisp://dictate` URL
/// delivery is exercised manually (scripts/run-sim.sh + the simctl openurl step in
/// the PR checklist), which cannot be made hermetic inside XCUITest.
final class DictationHandoffUITests: XCTestCase {

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

        // The published text is the scripted fake's fixed final.
        let text = app.staticTexts["sheet.publishedText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5),
                      "the published transcript text was not shown")
        XCTAssertTrue(
            (text.label).contains("scripted dictation for UI testing"),
            "unexpected published text: \(text.label)"
        )
    }
}
