import XCTest
@testable import KeyboardCore
import MobileCore

/// Exhaustive cases for the pure live-partial render model (WP10c, D12). The model
/// tracks only the last-rendered string per capture and turns each incoming
/// `LivePartial` into a minimal proxy edit (via `LiveInsertDiffer`) or an ignore.
///
/// The through-line invariant: replaying a capture's decisions against a simulated
/// field (delete-suffix + insert) reproduces exactly the last non-ignored text.
final class LivePartialRenderModelTests: XCTestCase {

    private let cap = UUID()

    private func partial(_ cid: UUID, _ seq: Int, _ text: String, final: Bool = false) -> LivePartial {
        LivePartial(captureID: cid, seq: seq, text: text, isFinal: final, updatedAt: Date())
    }

    /// Apply a decision to a simulated field the way the proxy would.
    private func applyToField(_ field: inout String, _ decision: LivePartialRenderModel.Decision) {
        guard case let .edit(deleteBackward, insert) = decision else { return }
        var chars = Array(field)
        chars.removeLast(min(deleteBackward, chars.count))
        field = String(chars) + insert
    }

    // MARK: - Happy path: prefix growth streams as pure inserts

    func testPrefixGrowthRendersIncrementally() {
        var m = LivePartialRenderModel()
        var field = ""

        for (i, text) in ["he", "hel", "hello", "hello wo", "hello world"].enumerated() {
            let d = m.apply(partial(cap, i, text), isSecureField: false)
            if case let .edit(del, ins) = d {
                XCTAssertEqual(del, 0, "prefix growth should never delete")
                _ = ins
            } else {
                XCTFail("expected an edit for \(text)")
            }
            applyToField(&field, d)
        }
        XCTAssertEqual(field, "hello world")
        XCTAssertEqual(m.rendered, "hello world")
    }

    // MARK: - Mid-string revision deletes only the diverging tail

    func testMidStringRevision() {
        var m = LivePartialRenderModel()
        var field = ""
        _ = { applyToField(&field, m.apply(partial(cap, 0, "recognize speach"), isSecureField: false)) }()
        let d = m.apply(partial(cap, 1, "recognize speech"), isSecureField: false)
        // "recognize spe" is the common prefix; "ach" (3) deleted, "ech" inserted.
        XCTAssertEqual(d, .edit(deleteBackward: 3, insert: "ech"))
        applyToField(&field, d)
        XCTAssertEqual(field, "recognize speech")
    }

    // MARK: - Out-of-order / duplicate seq is ignored

    func testSeqRegressionIgnored() {
        var m = LivePartialRenderModel()
        _ = m.apply(partial(cap, 5, "hello"), isSecureField: false)
        XCTAssertEqual(m.apply(partial(cap, 4, "hell"), isSecureField: false), .ignore)
        XCTAssertEqual(m.apply(partial(cap, 5, "hello again"), isSecureField: false), .ignore,
                       "same seq is a duplicate, ignored")
        // Tracking is untouched by the ignored partials.
        XCTAssertEqual(m.rendered, "hello")
        XCTAssertEqual(m.lastSeq, 5)
        // A higher seq resumes normally.
        XCTAssertEqual(m.apply(partial(cap, 6, "hello!"), isSecureField: false),
                       .edit(deleteBackward: 0, insert: "!"))
    }

    // MARK: - captureID switch resets tracking (fresh insert, no cross-delete)

    func testCaptureIDSwitchResetsTracking() {
        var m = LivePartialRenderModel()
        _ = m.apply(partial(cap, 3, "first capture"), isSecureField: false)

        let other = UUID()
        let d = m.apply(partial(other, 0, "second"), isSecureField: false)
        // New capture starts from empty → pure insert, NOT a delete of "first capture".
        XCTAssertEqual(d, .edit(deleteBackward: 0, insert: "second"))
        XCTAssertEqual(m.captureID, other)
        XCTAssertEqual(m.lastSeq, 0)
        XCTAssertEqual(m.rendered, "second")
    }

    // MARK: - Final swaps in cleaned text and clears tracking

    func testFinalSwapAndClear() {
        var m = LivePartialRenderModel()
        var field = ""
        applyToField(&field, m.apply(partial(cap, 0, "hello world"), isSecureField: false))
        // The cleaned final capitalizes + punctuates.
        let d = m.apply(partial(cap, 1, "Hello world.", final: true), isSecureField: false)
        applyToField(&field, d)
        XCTAssertEqual(field, "Hello world.")
        // Tracking cleared: next partial starts a fresh capture from empty.
        XCTAssertNil(m.captureID)
        XCTAssertNil(m.lastSeq)
        XCTAssertEqual(m.rendered, "")
    }

    func testFinalWithSameSeqAsLastPartialStillApplies() {
        var m = LivePartialRenderModel()
        _ = m.apply(partial(cap, 7, "hi"), isSecureField: false)
        // Some hosts stamp the final with the same seq as the last partial — it must
        // NOT be swallowed as a regression.
        // "hi" → "Hi." shares no prefix (h ≠ H), so both chars delete, "Hi." inserts.
        let d = m.apply(partial(cap, 7, "Hi.", final: true), isSecureField: false)
        XCTAssertEqual(d, .edit(deleteBackward: 2, insert: "Hi."))
        XCTAssertNil(m.captureID)
    }

    // MARK: - Secure field suppresses BEFORE any edit or state change

    func testSecureFieldSuppressesEntirely() {
        var m = LivePartialRenderModel()
        XCTAssertEqual(m.apply(partial(cap, 0, "password text"), isSecureField: true), .ignore)
        // No tracking mutation at all — nothing was (or will be) rendered.
        XCTAssertNil(m.captureID)
        XCTAssertNil(m.lastSeq)
        XCTAssertEqual(m.rendered, "")

        // Even a final is suppressed in a secure field (WP5 pending path handles it).
        XCTAssertEqual(m.apply(partial(cap, 1, "Password text.", final: true), isSecureField: true), .ignore)
        XCTAssertNil(m.captureID)
    }

    func testSecureFieldMidStreamStopsFurtherRendering() {
        var m = LivePartialRenderModel()
        // Rendered while non-secure...
        _ = m.apply(partial(cap, 0, "visible"), isSecureField: false)
        XCTAssertEqual(m.rendered, "visible")
        // ...then the field turns secure (focus moved): further partials are ignored
        // and tracking is frozen (the shell separately stops the loop, but the model
        // is safe regardless).
        XCTAssertEqual(m.apply(partial(cap, 1, "visible secret"), isSecureField: true), .ignore)
        XCTAssertEqual(m.rendered, "visible")
    }

    // MARK: - Emoji / combining marks count as single graphemes

    func testGraphemeSafeRevision() {
        var m = LivePartialRenderModel()
        var field = ""
        applyToField(&field, m.apply(partial(cap, 0, "hi 👍🏽"), isSecureField: false))
        // Revise the emoji away: one grapheme cluster deleted, not several scalars.
        let d = m.apply(partial(cap, 1, "hi 🎉"), isSecureField: false)
        XCTAssertEqual(d.deleteBackwardOrNil, 1)
        applyToField(&field, d)
        XCTAssertEqual(field, "hi 🎉")
    }

    // MARK: - reset() clears tracking

    func testResetClears() {
        var m = LivePartialRenderModel()
        _ = m.apply(partial(cap, 2, "text"), isSecureField: false)
        m.reset()
        XCTAssertNil(m.captureID)
        XCTAssertNil(m.lastSeq)
        XCTAssertEqual(m.rendered, "")
    }
}

private extension LivePartialRenderModel.Decision {
    /// `deleteBackward` when this is an edit, else nil — a test convenience.
    var deleteBackwardOrNil: Int? {
        if case let .edit(deleteBackward, _) = self { return deleteBackward }
        return nil
    }
}
