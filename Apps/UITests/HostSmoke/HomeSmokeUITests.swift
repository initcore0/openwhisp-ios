import XCTest

/// Tier-3 (simulator XCUITest) smoke test: launch the host app on a booted
/// simulator and assert the placeholder home screen (WP1 scaffold) actually
/// renders. This is the cheapest end-to-end proof that the app bundle installs,
/// links `OpenWhispMobileKit`, and reaches its first screen — the layer
/// `swift test` cannot cover because it never builds or launches the app.
///
/// Assertions are deliberately anchored on the stable copy the scaffold ships
/// (`HomeView`): the "OpenWhisp" navigation title and the "Scaffold (WP1)"
/// status row. When WP3 replaces the placeholder home with the real composer,
/// update these anchors (and prefer accessibility identifiers then).
final class HomeSmokeUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The app launches and the placeholder home renders.
    func testAppLaunchesAndHomeRenders() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertEqual(app.state, .runningForeground, "app did not reach the foreground")

        // Navigation title (rendered as a static text / other element in the nav bar).
        let title = app.staticTexts["OpenWhisp"]
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "home navigation title 'OpenWhisp' never appeared")

        // A stable row from the scaffold's HomeView proves the List rendered and
        // the app genuinely links MobileCore. The Status row is a SwiftUI
        // `LabeledContent`, which exposes the whole row as ONE element whose
        // *value* is "Scaffold (WP1)" (not a standalone static text) — so match
        // any element carrying that string in its label or value, rather than by
        // exact label. This is the robust way to assert on LabeledContent values.
        let scaffoldRow = app.descendants(matching: .any).matching(
            NSPredicate(format:
                "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Scaffold (WP1)", "Scaffold (WP1)")
        ).firstMatch
        XCTAssertTrue(scaffoldRow.waitForExistence(timeout: 5),
                      "expected the 'Scaffold (WP1)' status value to render")
    }

    /// The home content is non-trivial (guards against an app that launches to a
    /// blank window — a common silent failure when the SwiftUI root fails to
    /// resolve). We assert several of the scaffold's known labels are present.
    func testHomeShowsExpectedSections() {
        let app = XCUIApplication()
        app.launch()

        for label in ["OpenWhisp", "Status", "Bundle", "Version"] {
            let el = app.staticTexts[label]
            XCTAssertTrue(el.waitForExistence(timeout: 10),
                          "expected home to show the '\(label)' label")
        }
    }
}
