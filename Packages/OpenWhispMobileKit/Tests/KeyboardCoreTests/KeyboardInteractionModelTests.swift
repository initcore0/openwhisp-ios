import XCTest
@testable import KeyboardCore

final class KeyboardInteractionModelTests: XCTestCase {

    // MARK: - Backspace repeat cadence

    func testFirstRepeatUsesInitialDelay() {
        let c = BackspaceRepeatCadence.system
        XCTAssertEqual(c.delay(beforeRepeat: 1), c.initialDelay, accuracy: 1e-9)
        // index 0 / negative also map to the initial delay (defensive).
        XCTAssertEqual(c.delay(beforeRepeat: 0), c.initialDelay, accuracy: 1e-9)
    }

    func testSecondRepeatUsesStartInterval() {
        let c = BackspaceRepeatCadence.system
        XCTAssertEqual(c.delay(beforeRepeat: 2), c.startInterval, accuracy: 1e-9)
    }

    func testRepeatsAccelerateMonotonically() {
        let c = BackspaceRepeatCadence.system
        var previous = c.delay(beforeRepeat: 2)
        // Each subsequent repeat is <= the previous one (accelerating), until the
        // floor, and never below the floor.
        for index in 3...40 {
            let d = c.delay(beforeRepeat: index)
            XCTAssertLessThanOrEqual(d, previous + 1e-12,
                                     "repeat \(index) delay \(d) should not exceed the previous \(previous)")
            XCTAssertGreaterThanOrEqual(d, c.minInterval - 1e-12,
                                        "repeat \(index) delay \(d) fell below the floor \(c.minInterval)")
            previous = d
        }
    }

    func testCadenceClampsToMinInterval() {
        let c = BackspaceRepeatCadence.system
        // Far out, the interval has bottomed out at the floor.
        XCTAssertEqual(c.delay(beforeRepeat: 500), c.minInterval, accuracy: 1e-9)
    }

    func testWordDeletionKicksInAtThreshold() {
        let c = BackspaceRepeatCadence.system
        XCTAssertFalse(c.deletesWord(afterRepeats: c.wordDeletionThreshold - 1))
        XCTAssertTrue(c.deletesWord(afterRepeats: c.wordDeletionThreshold))
        XCTAssertTrue(c.deletesWord(afterRepeats: c.wordDeletionThreshold + 5))
    }

    // MARK: - Backspace hold (tap vs. repeat, slide-off) — MINOR 3

    func testPlainTapEmitsExactlyOneBackspace() {
        var hold = BackspaceHold()
        hold.begin()
        // No repeats fired → a plain tap.
        XCTAssertTrue(hold.releaseWasPlainTap)
    }

    func testHoldThatFiredRepeatsIsNotAPlainTap() {
        var hold = BackspaceHold()
        hold.begin()
        hold.fireRepeat()
        hold.fireRepeat()
        XCTAssertEqual(hold.liveRepeatCount, 2)
        XCTAssertEqual(hold.repeatsFired, 2)
        XCTAssertFalse(hold.releaseWasPlainTap,
                       "a hold that fired repeats must not emit an extra backspace on release")
    }

    func testSlideOffPreservesFiredTallySoReleaseIsNotAPlainTap() {
        // The exact MINOR 3 bug: repeats fire, the finger slides off (resetting the
        // LIVE counter), then the finger lifts. The release must NOT look like a tap.
        var hold = BackspaceHold()
        hold.begin()
        hold.fireRepeat()
        hold.fireRepeat()
        hold.fireRepeat()
        hold.slideOff()
        XCTAssertEqual(hold.liveRepeatCount, 0, "slide-off resets the live cadence counter")
        XCTAssertEqual(hold.repeatsFired, 3, "…but preserves the fired tally")
        XCTAssertFalse(hold.releaseWasPlainTap,
                       "release after a slide-off (with repeats already fired) is NOT a plain tap")
    }

    func testSlideOffWithNoRepeatsIsStillATap() {
        // Slide off immediately after touch-down, before any repeat fired: still a tap.
        var hold = BackspaceHold()
        hold.begin()
        hold.slideOff()
        XCTAssertTrue(hold.releaseWasPlainTap)
    }

    func testBeginResetsBothCountersForNextHold() {
        var hold = BackspaceHold()
        hold.begin()
        hold.fireRepeat()
        hold.slideOff()
        hold.begin()   // next hold
        XCTAssertEqual(hold.liveRepeatCount, 0)
        XCTAssertEqual(hold.repeatsFired, 0)
        XCTAssertTrue(hold.releaseWasPlainTap)
    }

    // MARK: - Double-tap detection

    func testDoubleTapIntervalBoundary() {
        XCTAssertTrue(KeyboardGesture.isDoubleTap(interval: 0.0))
        XCTAssertTrue(KeyboardGesture.isDoubleTap(interval: KeyboardGesture.doubleTapInterval))
        XCTAssertFalse(KeyboardGesture.isDoubleTap(interval: KeyboardGesture.doubleTapInterval + 0.01))
        XCTAssertFalse(KeyboardGesture.isDoubleTap(interval: -0.1))
    }

    // MARK: - Double-tap space → ". "

    func testDoubleTapSpaceAfterWordMakesPeriodSpace() {
        // "hello " → double-tap space → "hello. "
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: "hello "), .periodSpace)
        // A digit ends a "word" too ("item 2 " → "item 2. ").
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: "item 2 "), .periodSpace)
    }

    func testDoubleTapSpaceNotAfterTrailingSpace() {
        // No trailing space (caret right after the letter) → plain.
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: "hello"), .plainSpace)
        // Two spaces already → don't compound into ".  ".
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: "hello  "), .plainSpace)
    }

    func testDoubleTapSpaceNotAfterPunctuation() {
        // "end. " → don't make "end.. "
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: "end. "), .plainSpace)
        // "wow! " → plain (previous non-space is punctuation, not a word char).
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: "wow! "), .plainSpace)
    }

    func testDoubleTapSpaceAtFieldStartIsPlain() {
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: nil), .plainSpace)
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: ""), .plainSpace)
        // A lone leading space is not a word end.
        XCTAssertEqual(KeyboardGesture.spaceDoubleTap(contextBeforeCaret: " "), .plainSpace)
    }

    // MARK: - Double-tap shift → caps lock

    func testDoubleTapShiftLocksFromOffOrOn() {
        XCTAssertEqual(KeyboardGesture.shiftAfterDoubleTap(from: .off), .capsLock)
        XCTAssertEqual(KeyboardGesture.shiftAfterDoubleTap(from: .on), .capsLock)
    }

    func testDoubleTapShiftReleasesFromLock() {
        XCTAssertEqual(KeyboardGesture.shiftAfterDoubleTap(from: .capsLock), .off)
    }

    // MARK: - Mic-key refresh triggers

    func testReturnTripTriggersAutoInsert() {
        XCTAssertTrue(MicKeyRefreshTrigger.viewWillAppear.performsAutoInsert)
        XCTAssertTrue(MicKeyRefreshTrigger.darwinPing.performsAutoInsert)
        XCTAssertTrue(MicKeyRefreshTrigger.micTap.performsAutoInsert)
    }

    func testPollTriggerDoesNotAutoInsert() {
        XCTAssertFalse(MicKeyRefreshTrigger.captureStatePoll.performsAutoInsert,
                       "a repeating poll tick must not auto-insert or it double-inserts")
    }

    func testAllTriggersCovered() {
        // Guard against a new trigger silently defaulting its auto-insert behavior.
        XCTAssertEqual(Set(MicKeyRefreshTrigger.allCases),
                       [.viewWillAppear, .darwinPing, .captureStatePoll, .micTap])
    }
}
