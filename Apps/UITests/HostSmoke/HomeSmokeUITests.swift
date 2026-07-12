import XCTest

/// Tier-3 (simulator XCUITest) smoke test: launch the host app on a booted
/// simulator and assert the real UI (WP3) renders — the main TabView (Dictate /
/// History / Settings), and that the Engine Lab opens and lists its bundled
/// fixtures.
///
/// Deterministic + CI-safe: launched with `-uitest-skip-onboarding` so the app
/// lands directly on the TabView (no onboarding, no model download), and the test
/// never records audio or downloads a model — it only navigates and asserts static
/// structure.
final class HomeSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-skip-onboarding"]
        app.launch()
        return app
    }

    /// The app launches to the main TabView and the composer renders.
    func testAppLaunchesToComposer() {
        let app = launchApp()
        XCTAssertEqual(app.state, .runningForeground, "app did not reach the foreground")

        // The Dictate tab is selected by default; its record button carries a stable id.
        let record = app.buttons["composer.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 10),
                      "composer record button never appeared")

        // The three tabs exist.
        for tab in ["Dictate", "History", "Settings"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 5),
                          "expected the '\(tab)' tab")
        }
    }

    /// Navigating to Settings → Engine Lab opens the Lab and lists fixtures.
    func testEngineLabOpensAndListsFixtures() {
        let app = launchApp()

        // Go to the Settings tab.
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab missing")
        settingsTab.tap()

        // Open the Engine Lab from the Developer section. It sits below the other
        // Settings sections (Sync / Models / Privacy), so swipe it into view before
        // asserting — a Form only realizes rows near the viewport.
        let labRow = app.buttons["settings.engineLab"]
        var labSwipes = 0
        while !labRow.exists && labSwipes < 6 {
            app.swipeUp()
            labSwipes += 1
        }
        XCTAssertTrue(labRow.waitForExistence(timeout: 10), "Engine Lab row missing")
        labRow.tap()

        // The Lab lists the bundled fixtures (Debug builds bundle them). The English
        // fixture is near the top — its presence proves the Lab resolved the bundle.
        let plain = app.staticTexts["Plain speech (pangram)"]
        XCTAssertTrue(plain.waitForExistence(timeout: 10),
                      "Engine Lab did not list the English fixture (bundle resolution failed?)")

        // A multilingual fixture (the product's headline) lives further down the
        // scroll; swipe until it's realized, then assert. Bounded so a genuinely
        // missing fixture still fails rather than looping forever.
        let russian = app.staticTexts["Russian greeting"]
        var swipes = 0
        while !russian.exists && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(russian.waitForExistence(timeout: 5),
                      "Engine Lab did not list the multilingual fixture")
    }
}
