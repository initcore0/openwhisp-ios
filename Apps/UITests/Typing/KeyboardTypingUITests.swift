import XCTest

/// Types into a text field with the **system** keyboard and verifies the text
/// lands. This proves the UI-test harness can drive real text entry on a booted
/// simulator — the prerequisite for the eventual keyboard-extension tests
/// (WP4/WP5) — without depending on OUR keyboard extension being enabled.
///
/// Deliberately NOT testing our keyboard extension here: enabling a custom
/// keyboard programmatically via XCUITest (navigating Settings ▸ General ▸
/// Keyboard ▸ Keyboards ▸ Add New Keyboard, then toggling Full Access) is
/// notoriously flaky across iOS versions and simulator states. That path is
/// documented as a manual/real-device checklist in docs/TESTING.md instead of
/// shipped as a flaky CI test. This test uses the system keyboard against a
/// dedicated harness surface (`UITestHost`) so it is deterministic.
final class KeyboardTypingUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTypeIntoTextFieldWithSystemKeyboard() {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["uitest.textField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10),
                      "the harness text field never appeared")

        field.tap()
        // Give the system keyboard a moment to present, then type.
        let phrase = "Hello, world!"
        field.typeText(phrase)

        // Read the value back off the field itself.
        let value = field.value as? String ?? ""
        XCTAssertEqual(value, phrase,
                       "typed text did not land in the field (got '\(value)')")

        // And off the echo label bound to the same @State — proves the text
        // propagated through SwiftUI, not just into the field's buffer.
        let echo = app.staticTexts["uitest.echo"]
        XCTAssertTrue(echo.waitForExistence(timeout: 5))
        XCTAssertEqual(echo.label, phrase, "echo label did not reflect the typed text")
    }
}
