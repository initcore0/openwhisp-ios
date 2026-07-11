import XCTest
import MobileCore
import OpenWhispCore
@testable import CaptureKit

/// OPT-IN evidence generator (gated by `OPENWHISP_E2E_ENGINES=1`): runs the English
/// pangram fixture through the WhisperKit `tiny.en` file engine — the exact
/// `FileTranscriptionEngine` seam the Engine Lab uses — scores it with the same
/// `WordErrorRate` util, and writes the result as a JSON artifact so the "real
/// engine works end-to-end through the Lab path" claim is reproducible.
///
///   OPENWHISP_E2E_ENGINES=1 OPENWHISP_LAB_EVIDENCE_OUT=/path/lab-evidence.json \
///     swift test --filter LabEvidenceE2ETests
final class LabEvidenceE2ETests: XCTestCase {
    func testWriteLabEvidenceForPangram() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENWHISP_E2E_ENGINES"] == "1",
            "set OPENWHISP_E2E_ENGINES=1 to generate Lab evidence"
        )
        guard let fixture = Bundle.module.url(
            forResource: "plain_speech", withExtension: "wav", subdirectory: "Fixtures"
        ) else { throw XCTSkip("fixture not bundled") }

        let reference = "The quick brown fox jumps over the lazy dog."
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-evidence-\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: fixture, to: temp)

        let engine = WhisperKitMobileFileEngine(modelName: "openai_whisper-tiny.en")
        let start = Date()
        let hypothesis = try await transcribe(engine: engine, wavPath: temp.path)
        let latency = Date().timeIntervalSince(start)

        let scored = WordErrorRate.score(reference: reference, hypothesis: hypothesis)
        XCTAssertLessThan(scored.wer, 0.5, "tiny.en should get most of the pangram")

        let evidence: [String: Any] = [
            "engine": "WhisperKit openai_whisper-tiny.en (file engine)",
            "fixture": "plain_speech.wav",
            "reference": reference,
            "hypothesis": hypothesis,
            "wer": scored.werPercentString,
            "substitutions": scored.substitutions,
            "deletions": scored.deletions,
            "insertions": scored.insertions,
            "latencySeconds": String(format: "%.2f", latency),
            "note": "Generated on the swift-test host through the same FileTranscriptionEngine seam the iOS Engine Lab uses.",
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        print("LAB_EVIDENCE_JSON_BEGIN")
        print(String(decoding: data, as: UTF8.self))
        print("LAB_EVIDENCE_JSON_END")
        if let out = ProcessInfo.processInfo.environment["OPENWHISP_LAB_EVIDENCE_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
    }

    private func transcribe(engine: FileTranscriptionEngine, wavPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let box = OnceBox(continuation)
            engine.onTranscriptionComplete = { rid, text in if rid == id { box.ok(text) } }
            engine.onTranscriptionError = { rid, msg in if rid == id { box.err(msg) } }
            engine.transcribe(requestID: id, binaryPath: "", modelPath: "", language: "en",
                              wavPath: wavPath, deleteWhenDone: true, backend: .cli, prompt: "")
        }
    }
}

private final class OnceBox: @unchecked Sendable {
    private let c: CheckedContinuation<String, Error>
    private let lock = NSLock(); private var done = false
    init(_ c: CheckedContinuation<String, Error>) { self.c = c }
    func ok(_ v: String) { lock.lock(); defer { lock.unlock() }; if !done { done = true; c.resume(returning: v) } }
    func err(_ m: String) { lock.lock(); defer { lock.unlock() }; if !done { done = true; c.resume(throwing: NSError(domain: "lab", code: 1, userInfo: [NSLocalizedDescriptionKey: m])) } }
}
