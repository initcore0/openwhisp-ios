import XCTest
import MobileCore
import OpenWhispCore
@testable import CaptureKit

/// OPT-IN real-engine E2E — runs an ACTUAL transcription engine over a fixture WAV.
///
/// GATED behind `OPENWHISP_E2E_ENGINES=1` because it downloads a ~600 MB CoreML
/// model on first run and needs a Metal/ANE-capable host (a real device or a
/// GPU-backed simulator) — the opposite of the always-green `swift test` gate. The
/// testing infrastructure (which owns `scripts/`) invokes it by setting the env var;
/// every other run SKIPS it cleanly, so `swift test` stays fast and deterministic.
///
///   OPENWHISP_E2E_ENGINES=1 swift test --filter RealEngineE2ETests
///
/// The default engine exercised is Parakeet TDT v3 (the file/batch path). Set
/// `OPENWHISP_E2E_ENGINE=whisperkit` to run the WhisperKit file engine instead.
/// A custom fixture can be supplied via `OPENWHISP_E2E_FIXTURE=/path/to.wav`;
/// otherwise the bundled `Fixtures/plain_speech.wav` is used.
final class RealEngineE2ETests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["OPENWHISP_E2E_ENGINES"] == "1"
    }

    private func fixtureURL() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["OPENWHISP_E2E_FIXTURE"] {
            return URL(fileURLWithPath: path)
        }
        // Bundled resource (Package.swift .copy("Fixtures")).
        guard let url = Bundle.module.url(
            forResource: "plain_speech", withExtension: "wav", subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("bundled fixture plain_speech.wav not found")
        }
        return url
    }

    func testFileEngineTranscribesFixture() async throws {
        try XCTSkipUnless(isEnabled, "set OPENWHISP_E2E_ENGINES=1 to run the real-engine E2E")

        let fixture = try fixtureURL()
        // Work on a COPY — the engines delete the WAV when `deleteWhenDone` is true.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: fixture, to: temp)

        let engineChoice = ProcessInfo.processInfo.environment["OPENWHISP_E2E_ENGINE"] ?? "parakeet"
        let engine: FileTranscriptionEngine = engineChoice == "whisperkit"
            ? WhisperKitMobileFileEngine(modelName: "openai_whisper-tiny.en")
            : ParakeetMobileFileEngine()

        let result = try await transcribe(engine: engine, wavPath: temp.path, language: "en")
        // plain_speech.wav = "The quick brown fox jumps over the lazy dog."
        let lower = result.lowercased()
        XCTAssertTrue(lower.contains("quick") && lower.contains("fox"),
                      "expected the pangram, got: \(result)")
    }

    /// Bridge the callback-based `FileTranscriptionEngine` to async/await.
    private func transcribe(
        engine: FileTranscriptionEngine, wavPath: String, language: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let box = ResumeOnce(continuation)
            engine.onTranscriptionComplete = { rid, text in
                guard rid == id else { return }
                box.resume(returning: text)
            }
            engine.onTranscriptionError = { rid, message in
                guard rid == id else { return }
                box.resume(throwing: FakeError(message: message))
            }
            engine.transcribe(
                requestID: id, binaryPath: "", modelPath: "", language: language,
                wavPath: wavPath, deleteWhenDone: true, backend: .cli, prompt: ""
            )
        }
    }
}

/// Ensures a checked continuation resumes exactly once even if the engine fires
/// both complete and error (defensive).
private final class ResumeOnce: @unchecked Sendable {
    private let continuation: CheckedContinuation<String, Error>
    private let lock = NSLock()
    private var done = false
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    func resume(returning value: String) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true
        continuation.resume(returning: value)
    }
    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true
        continuation.resume(throwing: error)
    }
}
