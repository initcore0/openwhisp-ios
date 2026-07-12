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

    func testAutocapDisabledDropsInitialOneShotShift() {
        // MINOR 5: a `.none` field (autocap disabled) must not stay armed at field
        // start — the keyboard would leading-cap the first character otherwise. The
        // model starts many fields with a one-shot `.on`; disabled autocap disarms it.
        var m = KeyboardLayoutModel(page: .letters, shift: .on, autocapEnabled: false)
        m.updateAutocap(contextBeforeCaret: nil)
        XCTAssertEqual(m.shift, .off, "disabled autocap disarms the field-start one-shot shift")
        XCTAssertEqual(m.apply(.character("h")), .text("h"),
                       "first character in a .none field is lowercase")
    }

    func testAutocapDisabledStillNeverTouchesCapsLock() {
        var m = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: false)
        m.updateAutocap(contextBeforeCaret: nil)
        XCTAssertEqual(m.shift, .capsLock, "a deliberate caps lock survives even with autocap off")
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

    // MARK: Casing resolves at emit time from base characters (BLOCKER 1)
    //
    // The UIKit layer bakes each key's `.character` action from `currentBaseRows()`
    // (uncased) and resolves casing only at `apply` time. These tests pin that
    // contract at the core so the "types ALL CAPS forever / stale-baked casing after
    // a page round-trip" regression can never come back through the model.

    func testBaseRowsAreAlwaysLowercaseRegardlessOfShift() {
        // The actions are built from these; if they were ever pre-cased the emitted
        // character would freeze at build time (the ALL-CAPS bug).
        for shift in [ShiftState.off, .on, .capsLock] {
            let m = KeyboardLayoutModel(page: .letters, shift: shift, autocapEnabled: false)
            XCTAssertEqual(m.currentBaseRows().first?.first, "q",
                           "base rows must stay uncased (shift=\(shift)) so actions carry the base char")
        }
    }

    func testEmittedCasingTracksLiveShiftFromBaseCharacter() {
        // Base "h" + shift .on emits "H", then the one-shot reverts and "e" is "e".
        var m = KeyboardLayoutModel(page: .letters, shift: .on, autocapEnabled: false)
        let base = m.currentBaseRows()      // what the UI baked into the actions
        let h = base[1][5]                  // "asdfgh…" → index 5 is "h"
        XCTAssertEqual(h, "h")
        XCTAssertEqual(m.apply(.character(h)), .text("H"))
        XCTAssertEqual(m.shift, .off, "one-shot reverts after one character")
        XCTAssertEqual(m.apply(.character("e")), .text("e"), "casing tracks live state, not baked")
    }

    func testCapsLockEmitsCapsPersistentlyFromBaseCharacter() {
        var m = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: false)
        XCTAssertEqual(m.apply(.character("h")), .text("H"))
        XCTAssertEqual(m.apply(.character("e")), .text("E"))
        XCTAssertEqual(m.apply(.character("y")), .text("Y"))
        XCTAssertEqual(m.shift, .capsLock, "caps lock persists across characters")
    }

    func testEmittedCasingTracksLiveStateAfterPageRoundTrips() {
        // 123 → #+= → ABC round-trip with shift off: letters must emit LOWERCASE.
        // The old UIKit layer baked cased actions and went stale after this trip.
        var m = KeyboardLayoutModel(page: .letters, shift: .off, autocapEnabled: false)
        _ = m.apply(.page(.numbers))
        _ = m.apply(.page(.symbols))
        _ = m.apply(.page(.letters))
        XCTAssertEqual(m.shift, .off, "returning to letters with shift off stays off")
        XCTAssertEqual(m.apply(.character("h")), .text("h"))
        XCTAssertEqual(m.apply(.character("e")), .text("e"))
        XCTAssertEqual(m.apply(.character("y")), .text("y"))

        // Now engage shift AFTER the round-trip: casing must follow the live state.
        _ = m.apply(.shift)                                  // → .on
        XCTAssertEqual(m.apply(.character("h")), .text("H"))
        XCTAssertEqual(m.apply(.character("i")), .text("i"), "one-shot consumed, back to lowercase")
    }

    func testDisplayedFaceAndEmittedCharacterAgreeForEveryLetter() {
        // The face (currentRows, cased) and the emit (apply on the base char) must
        // never diverge — the UIKit layer titles from one and acts from the other.
        var m = KeyboardLayoutModel(page: .letters, shift: .capsLock, autocapEnabled: false)
        let faces = m.currentRows().flatMap { $0 }
        let bases = m.currentBaseRows().flatMap { $0 }
        for (face, base) in zip(faces, bases) {
            XCTAssertEqual(m.apply(.character(base)), .text(face),
                           "emitted char for base '\(base)' must equal its shown face '\(face)'")
        }
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
