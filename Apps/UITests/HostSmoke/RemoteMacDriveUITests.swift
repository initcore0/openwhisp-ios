import XCTest

/// Tier-3 XCUITest for the WP7 "drive your Mac" surface. Two facets:
///   1. Not-paired empty state: with no paired Mac, the drive controls are ABSENT
///      and the Pair entry point shows (the drive UI never leaks into an unpaired
///      device).
///   2. Paired + stubbed: with `-uitest-remote-stub`, the drive section renders,
///      and tapping Remote dictate returns the stub's canned text on-screen — no
///      Mac, camera, or LAN required.
final class RemoteMacDriveUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func openYourMac(extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-skip-onboarding"] + extraArgs
        app.launch()
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab missing")
        settingsTab.tap()
        let row = app.buttons["settings.yourMac"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Your Mac row missing")
        row.tap()
        return app
    }

    /// Unpaired: no drive controls, only the Pair entry point.
    func testNotPairedShowsNoDriveControls() {
        let app = openYourMac()
        XCTAssertTrue(app.buttons["yourMac.pair"].waitForExistence(timeout: 5),
                      "Pair button should show when unpaired")
        // The drive controls must NOT be present without a paired Mac.
        XCTAssertFalse(app.buttons["remoteDrive.dictate"].exists,
                       "Remote-dictate control leaked into the unpaired state")
        XCTAssertFalse(app.buttons["remoteDrive.loadHistory"].exists,
                       "Remote-history control leaked into the unpaired state")
    }

    /// Scroll the Form until `element` is hittable (or give up after `maxSwipes`).
    /// The drive controls sit below the paired card in a tall Form, so a fresh
    /// viewport may not have realized them yet.
    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 3), element.isHittable { return true }
        for _ in 0..<maxSwipes {
            if element.exists, element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// Paired + stubbed: the drive section renders and remote dictate shows text.
    func testPairedRendersDriveControlsAndDictateReturnsText() {
        let app = openYourMac(extraArgs: ["-uitest-remote-stub"])

        // The paired card renders (the drive UI hangs off it), not the Pair entry.
        XCTAssertFalse(app.buttons["yourMac.pair"].waitForExistence(timeout: 3),
                       "Pair entry should be gone when a Mac is paired")

        // The drive controls render under the paired card (scroll to reach them).
        let dictate = app.buttons["remoteDrive.dictate"]
        XCTAssertTrue(scrollTo(app, dictate), "Remote-dictate control missing when paired")

        // Tapping Remote dictate returns the stub's canned text on-screen.
        dictate.tap()
        let result = app.staticTexts["Heard you loud and clear."]
        XCTAssertTrue(result.waitForExistence(timeout: 8),
                      "Remote-dictate result text did not appear")
    }

    /// Paired + stubbed: Browse history renders the stubbed rows.
    func testPairedRemoteHistoryRendersRows() {
        let app = openYourMac(extraArgs: ["-uitest-remote-stub"])
        let load = app.buttons["remoteDrive.loadHistory"]
        XCTAssertTrue(scrollTo(app, load), "Load-history control missing")
        load.tap()
        XCTAssertTrue(app.staticTexts["First remembered note"].waitForExistence(timeout: 8),
                      "Stubbed history row did not appear")
    }
}
