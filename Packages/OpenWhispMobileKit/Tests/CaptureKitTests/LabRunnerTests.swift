import XCTest
import MobileCore
import OpenWhispCore
@testable import CaptureKit

/// Tests for the Lab runner's pure/deterministic pieces: engine-selection metadata
/// (display name / kind / model id) and audio-duration measurement over a bundled
/// fixture WAV. These don't run any model, so they stay on the always-green gate.
/// The real transcription path is covered by the env-gated `RealEngineE2ETests`.
final class LabRunnerTests: XCTestCase {

    func testParakeetSelectionMetadata() {
        let sel = LabEngineSelection.parakeet(variantID: "nemotron-multilingual-1120ms")
        XCTAssertEqual(sel.kind, .parakeet)
        XCTAssertEqual(sel.modelID, "nemotron-multilingual-1120ms")
        XCTAssertEqual(sel.displayName, ParakeetCatalog.variant(for: "nemotron-multilingual-1120ms").name)
    }

    func testWhisperKitSelectionMetadata() {
        let sel = LabEngineSelection.whisperKit(modelID: "openai_whisper-tiny.en")
        XCTAssertEqual(sel.kind, .whisperKit)
        XCTAssertEqual(sel.modelID, "openai_whisper-tiny.en")
        XCTAssertTrue(sel.displayName.contains("WhisperKit"))
    }

    func testAppleBaselineSelectionMetadata() {
        let sel = LabEngineSelection.appleBaseline(locale: "ru-RU")
        XCTAssertEqual(sel.kind, .appleBaseline)
        XCTAssertEqual(sel.modelID, "apple:ru-RU")
        XCTAssertTrue(sel.displayName.contains("ru-RU"))
    }

    /// Audio duration is read off the WAV header — deterministic, no engine.
    func testAudioDurationOfBundledFixture() throws {
        guard let url = Bundle.module.url(
            forResource: "plain_speech", withExtension: "wav", subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("bundled fixture plain_speech.wav not found")
        }
        let duration = LabRunner.audioDuration(of: url)
        XCTAssertGreaterThan(duration, 0.3, "pangram WAV should be well over 0.3s")
        XCTAssertLessThan(duration, 30, "pangram WAV should be under 30s")
    }

    func testResidentSizeIsNonNegative() {
        XCTAssertGreaterThanOrEqual(LabRunner.residentSizeBytes(), 0)
    }
}
