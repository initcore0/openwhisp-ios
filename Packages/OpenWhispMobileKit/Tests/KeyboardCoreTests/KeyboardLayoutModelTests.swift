import XCTest
@testable import KeyboardCore

final class KeyboardLayoutModelTests: XCTestCase {

    // MARK: Shift state machine

    func testShiftCyclesOffOnCapsLock() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        XCTAssertEqual(m.shift, .off)
        _ = m.apply(.shift)
        XCTAssertEqual(m.shift, .on)
        _ = m.apply(.shift)
        XCTAssertEqual(m.shift, .capsLock)
        _ = m.apply(.shift)
        XCTAssertEqual(m.shift, .off)
    }

    func testOneShotShiftConsumedByCharacter() {
        var m = KeyboardLayoutModel(page: .letters, shift: .on, autocapEnabled: false)
        let out = m.apply(.character("a"))
        XCTAssertEqual(out, .text("A"))
        XCTAssertEqual(m.shift, .off, "one-shot shift falls back to off after a character")
    }

    func testCapsLockPersistsAcrossCharacters() {
        var m = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: false)
        XCTAssertEqual(m.apply(.character("a")), .text("A"))
        XCTAssertEqual(m.shift, .capsLock)
        XCTAssertEqual(m.apply(.character("b")), .text("B"))
        XCTAssertEqual(m.shift, .capsLock)
    }

    func testLowercaseWhenShiftOff() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        XCTAssertEqual(m.apply(.character("q")), .text("q"))
    }

    func testSpaceConsumesOneShotShiftButNotCapsLock() {
        var one = KeyboardLayoutModel(page: .letters, shift: .on, autocapEnabled: false)
        XCTAssertEqual(one.apply(.space), .text(" "))
        XCTAssertEqual(one.shift, .off)

        var caps = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: false)
        XCTAssertEqual(caps.apply(.space), .text(" "))
        XCTAssertEqual(caps.shift, .capsLock)
    }

    // MARK: Page transitions

    func testPageTransitions() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        _ = m.apply(.page(.numbers))
        XCTAssertEqual(m.page, .numbers)
        _ = m.apply(.page(.symbols))
        XCTAssertEqual(m.page, .symbols)
        _ = m.apply(.page(.letters))
        XCTAssertEqual(m.page, .letters)
    }

    func testLeavingLettersDropsShift() {
        var m = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: false)
        _ = m.apply(.page(.numbers))
        XCTAssertEqual(m.shift, .off, "caps lock is a letters concept; normalized off when leaving")
    }

    func testDigitsAndSymbolsNotCasedByShift() {
        var m = KeyboardLayoutModel(page: .numbers, shift: .on, autocapEnabled: false)
        // On non-letters page a one-shot shift shouldn't uppercase a digit.
        XCTAssertEqual(m.apply(.character("1")), .text("1"))
    }

    // MARK: Autocap

    func testAutocapArmsAtFieldStart() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: true)
        m.updateAutocap(contextBeforeCaret: nil)
        XCTAssertEqual(m.shift, .on)
        m.updateAutocap(contextBeforeCaret: "")
        XCTAssertEqual(m.shift, .on)
    }

    func testAutocapArmsAfterSentenceTerminatorAndSpace() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: true)
        m.updateAutocap(contextBeforeCaret: "Hello. ")
        XCTAssertEqual(m.shift, .on)
    }

    func testAutocapDoesNotArmMidWord() {
        var m = KeyboardLayoutModel(page: .letters, shift: .on, autocapEnabled: true)
        m.updateAutocap(contextBeforeCaret: "Hello")
        XCTAssertEqual(m.shift, .off)
    }

    func testAutocapDoesNotArmAfterTerminatorWithoutSpace() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: true)
        // "e.g" — terminator not followed by whitespace → no autocap.
        m.updateAutocap(contextBeforeCaret: "e.g")
        XCTAssertEqual(m.shift, .off)
    }

    func testAutocapNeverOverridesCapsLock() {
        var m = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: true)
        m.updateAutocap(contextBeforeCaret: "hello")   // mid-word would disarm
        XCTAssertEqual(m.shift, .capsLock, "explicit caps lock is never overridden by autocap")
    }

    func testAutocapDisabledIsNoOp() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        m.updateAutocap(contextBeforeCaret: nil)
        XCTAssertEqual(m.shift, .off)
    }

    // MARK: Rendered rows

    func testLetterRowsUppercaseWhenShifted() {
        let lower = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        XCTAssertEqual(lower.currentRows().first?.first, "q")
        let upper = KeyboardLayoutModel(page: .letters, shift: .on, autocapEnabled: false)
        XCTAssertEqual(upper.currentRows().first?.first, "Q")
        let caps = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: false)
        XCTAssertEqual(caps.currentRows().first?.first, "Q")
    }

    func testRowsPerPage() {
        let letters = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        XCTAssertEqual(letters.currentRows().count, 3)
        XCTAssertEqual(letters.currentRows()[0].count, 10)

        let numbers = KeyboardLayoutModel(page: .numbers, shift: .off, autocapEnabled: false)
        XCTAssertEqual(numbers.currentRows()[0], ["1","2","3","4","5","6","7","8","9","0"])

        let symbols = KeyboardLayoutModel(page: .symbols, shift: .off, autocapEnabled: false)
        XCTAssertEqual(symbols.currentRows().count, 3)
        XCTAssertNotEqual(symbols.currentRows()[0], numbers.currentRows()[0])
    }

    // MARK: Non-character actions

    func testNonCharacterOutputs() {
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        XCTAssertEqual(m.apply(.backspace), .deleteBackward)
        XCTAssertEqual(m.apply(.returnKey), .submitReturn)
        XCTAssertEqual(m.apply(.globe), .switchInputMode)
        XCTAssertEqual(m.apply(.mic), .micTapped)
        XCTAssertEqual(m.apply(.refineLast), .refineLastTapped)
        XCTAssertEqual(m.apply(.shift), .none)
    }

    // MARK: Realistic typing sequence

    func testTypingHelloComma() {
        // Start armed by autocap at field start.
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: true)
        m.updateAutocap(contextBeforeCaret: nil)          // → .on
        XCTAssertEqual(m.apply(.character("h")), .text("H"))   // one-shot consumed
        XCTAssertEqual(m.apply(.character("e")), .text("e"))
        XCTAssertEqual(m.apply(.character("l")), .text("l"))
        XCTAssertEqual(m.apply(.character("l")), .text("l"))
        XCTAssertEqual(m.apply(.character("o")), .text("o"))
        // switch to numbers page for comma, type it, come back
        _ = m.apply(.page(.numbers))
        XCTAssertEqual(m.apply(.character(",")), .text(","))
        _ = m.apply(.page(.letters))
        XCTAssertEqual(m.apply(.space), .text(" "))
    }
}
