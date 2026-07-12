import XCTest

/// Drives the REAL OpenWhisp keyboard extension end-to-end on a simulator that has
/// the keyboard enabled system-wide (the harness scripts enable it via
/// `.GlobalPreferences AppleKeyboards` before running). Unlike
/// `KeyboardTypingUITests` — which deliberately uses the SYSTEM keyboard and is
/// CI-safe — this suite proves OUR keys type the right characters across the page
/// toggles that the adversarial review flagged (ALL-CAPS baking, page round-trips,
/// autocap on a `.none` field). It is gated behind an env flag so it only runs in
/// the dedicated live harness, never in the always-green CI lane.
final class OpenWhispKeyboardLiveUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Only runs when the harness has enabled our keyboard and set the flag.
    /// `xcodebuild` forwards `TEST_RUNNER_`-prefixed env vars to the runner process
    /// (stripping the prefix), so the harness sets
    /// `TEST_RUNNER_OPENWHISP_LIVE_KEYBOARD=1`.
    private var liveEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["OPENWHISP_LIVE_KEYBOARD"] == "1"
    }

    func testTypesAcrossPageTogglesWithOurKeyboard() throws {
        try XCTSkipUnless(liveEnabled, "live-keyboard suite runs only in the dedicated harness")

        let app = XCUIApplication(bundleIdentifier: "app.openwhisp.ios.uitesthost")
        app.launch()

        let field = app.textFields["uitest.textField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "harness text field never appeared")
        field.tap()

        // Switch to the OpenWhisp keyboard: cycle the Next-keyboard (globe) key until
        // OUR keyboard is up. The distinctive tell is our capital-"Shift" control
        // (the system keyboard labels its shift lowercase "shift") — the system
        // keyboard also has a "Dictate" button, so that label is NOT unique.
        switchToOpenWhispKeyboard(in: app)

        XCTAssertTrue(isOpenWhispKeyboardUp(app),
                      "the OpenWhisp keyboard never came up after cycling.\n\(dumpKeys(app))")

        // Type "Hey the 123 ok" — exercises: autocap at field start (.none field ⇒
        // NO leading cap), lowercase after the one-shot, a 123 page toggle for the
        // digits, and back to ABC. Because the harness field is `.never` autocap,
        // the expected result is the LITERAL "hey the 123 ok" (no capital H).
        // Our page-toggle keys expose accessibility LABELS ("Numbers"/"Letters"),
        // distinct from their visible titles ("123"/"ABC").
        tapKey(app, "H")          // face shows H if armed; on a .none field it's "h"
        tapLetter(app, "e", "y")
        tapKey(app, "space")
        tapLetter(app, "t", "h", "e")
        tapKey(app, "space")
        tapKey(app, "Numbers")    // "123" → numbers page
        tapLetter(app, "1", "2", "3")
        tapKey(app, "Letters")    // "ABC" → back to letters
        tapKey(app, "space")
        tapLetter(app, "o", "k")

        let echo = app.staticTexts["uitest.echo"]
        XCTAssertTrue(echo.waitForExistence(timeout: 5))
        // The `.none` field means autocap is suppressed → all lowercase.
        XCTAssertEqual(echo.label, "hey the 123 ok",
                       "typed text across page toggles did not land verbatim (got '\(echo.label)')")

        // Capture the live keyboard for the docs asset. When the harness sets
        // OPENWHISP_SHOT_PATH, write the full-screen screenshot there.
        if let shotPath = ProcessInfo.processInfo.environment["OPENWHISP_SHOT_PATH"] {
            let png = XCUIScreen.main.screenshot().pngRepresentation
            try? png.write(to: URL(fileURLWithPath: shotPath))
        }
    }

    /// BLOCKER 2: repeated page round-trips (123 → #+= → ABC → 123) must not shrink
    /// or collapse the rows. We drive several full round-trips and, after each,
    /// assert the letters page still has its full complement of keys at a stable
    /// height — proving the rebuild tears down old container views instead of
    /// stacking them under `.fillEqually`.
    func testPageRoundTripsKeepRowsStable() throws {
        try XCTSkipUnless(liveEnabled, "live-keyboard suite runs only in the dedicated harness")

        let app = XCUIApplication(bundleIdentifier: "app.openwhisp.ios.uitesthost")
        app.launch()
        let field = app.textFields["uitest.textField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        switchToOpenWhispKeyboard(in: app)
        XCTAssertTrue(isOpenWhispKeyboardUp(app), "OpenWhisp keyboard never came up.\n\(dumpKeys(app))")

        // Baseline: capture the letters-page 'q' key height.
        let baselineHeight = key(app, "q").frame.height
        XCTAssertGreaterThan(baselineHeight, 0)

        for trip in 1...4 {
            tapKey(app, "Numbers")   // 123
            tapKey(app, "Symbols")   // #+=
            tapKey(app, "Letters")   // ABC → back
            // The full letters page must be intact.
            XCTAssertTrue(key(app, "q").waitForExistence(timeout: 3),
                          "round-trip \(trip): 'q' missing → rows collapsed")
            XCTAssertTrue(key(app, "m").exists, "round-trip \(trip): 'm' missing")
            let h = key(app, "q").frame.height
            XCTAssertEqual(h, baselineHeight, accuracy: 2.0,
                           "round-trip \(trip): row height drifted (\(h) vs baseline \(baselineHeight)) → rows shrank")
        }
    }

    // MARK: - Helpers

    /// OUR keyboard is up iff a capital-"Shift" control exists (the system keyboard
    /// uses a lowercase "shift" label). This is the one unambiguous marker: the
    /// system keyboard also exposes a "Dictate" button and lowercase letter keys.
    private func isOpenWhispKeyboardUp(_ app: XCUIApplication) -> Bool {
        key(app, "Shift").exists
    }

    private func switchToOpenWhispKeyboard(in app: XCUIApplication) {
        // First, a few short globe taps (fast path if the cycle includes us).
        for _ in 0..<6 {
            if isOpenWhispKeyboardUp(app) { return }
            let globe = key(app, "Next keyboard")
            guard globe.exists else { break }
            globe.tap()
            _ = key(app, "Shift").waitForExistence(timeout: 1.0)
        }
        if isOpenWhispKeyboardUp(app) { return }

        // Fall back to the long-press keyboard picker and choose OpenWhisp by name.
        // The picker sheet is owned by SpringBoard, not the target app, so query it
        // through a SpringBoard XCUIApplication handle.
        let globe = key(app, "Next keyboard")
        guard globe.exists else { return }
        globe.press(forDuration: 1.3)

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for name in ["OpenWhisp", "OpenWhisp Keyboard", "OpenWhispKeyboard"] {
            let candidates = [
                springboard.buttons[name].firstMatch,
                springboard.staticTexts[name].firstMatch,
                springboard.cells[name].firstMatch,
                app.buttons[name].firstMatch,
                app.staticTexts[name].firstMatch,
            ]
            if let hit = candidates.first(where: { $0.waitForExistence(timeout: 1.0) }) {
                hit.tap()
                break
            }
        }
        _ = key(app, "Shift").waitForExistence(timeout: 3)
    }

    /// An element for a key by accessibility label. Our `KeyButton`s carry the
    /// `.keyboardKey` trait, so XCUITest surfaces them under `app.keys`; fall back to
    /// `.buttons` for anything mapped there.
    private func key(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let k = app.keys[label]
        return k.exists ? k : app.buttons[label]
    }

    /// Tap a key by its accessibility label. Letters carry their CASED face as the
    /// label (our `refreshFaces` keeps label == shown glyph), so "H" and "h" are
    /// distinct; try both cases for robustness where casing is state-dependent.
    private func tapKey(_ app: XCUIApplication, _ label: String) {
        let k = key(app, label)
        if k.waitForExistence(timeout: 3) {
            k.tap()
            return
        }
        // Casing may differ from what we asked (armed vs not). Try the other case.
        let alt = label.count == 1
            ? (label == label.uppercased() ? label.lowercased() : label.uppercased())
            : label
        let altKey = key(app, alt)
        XCTAssertTrue(altKey.waitForExistence(timeout: 3),
                      "key '\(label)'/'\(alt)' not found.\n\(dumpKeys(app))")
        altKey.tap()
    }

    private func tapLetter(_ app: XCUIApplication, _ letters: String...) {
        for l in letters { tapKey(app, l) }
    }

    /// Diagnostic: list the labels of every key/button currently on screen.
    private func dumpKeys(_ app: XCUIApplication) -> String {
        var lines: [String] = ["--- keys ---"]
        for e in app.keys.allElementsBoundByIndex { lines.append("key: '\(e.label)'") }
        lines.append("--- buttons ---")
        for e in app.buttons.allElementsBoundByIndex { lines.append("button: '\(e.label)'") }
        return lines.joined(separator: "\n")
    }
}
