import XCTest

/// Tier-3 XCUITest for the P2P-sync UI (WP6): Settings shows the "Your Mac"
/// section, and opening the pairing sheet on the SIMULATOR (no camera) surfaces
/// the graceful camera-unavailable fallback rather than a black screen or crash.
final class YourMacUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchToSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-skip-onboarding"]
        app.launch()
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab missing")
        settingsTab.tap()
        return app
    }

    /// Settings lists "Your Mac"; opening it shows the unpaired Pair entry point.
    func testYourMacSectionAndPairEntry() {
        let app = launchToSettings()

        let row = app.buttons["settings.yourMac"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Your Mac row missing from Settings")
        row.tap()

        XCTAssertTrue(app.otherElements["yourMac.root"].waitForExistence(timeout: 5)
                      || app.navigationBars["Your Mac"].waitForExistence(timeout: 5),
                      "Your Mac screen did not render")

        // No peers paired in a fresh test container → the Pair button is present.
        let pair = app.buttons["yourMac.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 5), "Pair a Mac button missing")
    }

    /// The pairing sheet opens; on the simulator the camera is unavailable, so the
    /// fallback copy must show (and the sheet is cancelable).
    func testPairingSheetShowsCameraFallbackOnSimulator() {
        let app = launchToSettings()
        app.buttons["settings.yourMac"].tap()

        let pair = app.buttons["yourMac.pair"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10), "Pair button missing")
        pair.tap()

        // The sheet root appears.
        XCTAssertTrue(app.otherElements["pairing.root"].waitForExistence(timeout: 5)
                      || app.navigationBars["Pair a Mac"].waitForExistence(timeout: 5),
                      "pairing sheet did not present")

        // On the simulator (no capture device) the fallback must appear.
        let fallback = app.otherElements["pairing.cameraUnavailable"]
        let fallbackText = app.staticTexts["Camera unavailable"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 8) || fallbackText.waitForExistence(timeout: 8),
                      "camera-unavailable fallback did not appear on the simulator")

        // Cancel closes the sheet cleanly.
        let cancel = app.buttons["pairing.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3), "Cancel button missing")
        cancel.tap()
        XCTAssertTrue(app.buttons["yourMac.pair"].waitForExistence(timeout: 5),
                      "did not return to the Your Mac screen after cancel")
    }
}
