import XCTest
@testable import MobileCore

/// The Live Activity content model is pure (no ActivityKit), so the mapping from
/// the capture pipeline's `CaptureState` to what the Dynamic Island draws is tested
/// here rather than trapped in the widget.
final class DictationActivityModelTests: XCTestCase {

    func testListeningCarriesLevel() {
        let s = DictationActivityState.from(.listening(level: 0.7))
        XCTAssertEqual(s.phase, .listening)
        XCTAssertEqual(s.level, 0.7, accuracy: 0.0001)
        XCTAssertFalse(s.isTerminal)
    }

    func testPreparingAndIdleAreStarting() {
        XCTAssertEqual(DictationActivityState.from(.preparing).phase, .starting)
        XCTAssertEqual(DictationActivityState.from(.idle).phase, .starting)
    }

    func testTranscribing() {
        XCTAssertEqual(DictationActivityState.from(.transcribing).phase, .transcribing)
    }

    func testPublishedIsInsertedAndTerminal() {
        let s = DictationActivityState.from(.published(UUID()))
        XCTAssertEqual(s.phase, .inserted)
        XCTAssertTrue(s.isTerminal)
    }

    func testFailedIsTerminal() {
        let s = DictationActivityState.from(.failed(.micDenied))
        XCTAssertEqual(s.phase, .failed)
        XCTAssertTrue(s.isTerminal)
    }

    func testLabelsAndSymbolsAreStableAndNonEmpty() {
        for phase in [DictationActivityPhase.starting, .listening, .transcribing, .inserted, .failed, .armed] {
            let s = DictationActivityState(phase: phase)
            XCTAssertFalse(s.label.isEmpty, "phase \(phase) has an empty label")
            XCTAssertFalse(s.symbolName.isEmpty, "phase \(phase) has an empty symbol")
        }
    }

    // MARK: - Session mapping (WP10b)

    func testFromSessionMapsPhases() {
        XCTAssertEqual(DictationActivityState.fromSession(.armed).phase, .armed)
        XCTAssertEqual(DictationActivityState.fromSession(.capturing).phase, .listening)
        XCTAssertEqual(DictationActivityState.fromSession(.transcribing).phase, .transcribing)
        XCTAssertEqual(DictationActivityState.fromSession(.off).phase, .inserted)
    }

    func testArmedIsSessionArmedAndNotTerminal() {
        let s = DictationActivityState(phase: .armed)
        XCTAssertTrue(s.isSessionArmed)
        XCTAssertFalse(s.isTerminal)
        XCTAssertFalse(DictationActivityState(phase: .listening).isSessionArmed)
    }

    func testCodableRoundTrip() throws {
        let s = DictationActivityState(phase: .listening, level: 0.42)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(DictationActivityState.self, from: data)
        XCTAssertEqual(s, back)
    }
}
