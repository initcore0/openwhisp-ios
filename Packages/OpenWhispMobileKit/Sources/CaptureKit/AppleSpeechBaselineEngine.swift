import Foundation
import Speech
import OpenWhispCore

/// Apple `SFSpeechRecognizer` baseline — BENCHMARK ONLY. It exists so the Engine
/// Lab (WP3) can measure OpenWhisp's engines against Apple's built-in on-device
/// recognizer on the SAME fixture audio, making "clearly better than Apple's
/// built-in, especially multilingual" (product Goal #1) a provable claim rather
/// than a vibe.
///
/// It is NEVER a production transcription path:
///   - It forces `requiresOnDeviceRecognition = true`, so nothing leaves the
///     device (local-first) — but that also means it only runs where Apple ships an
///     on-device model for the locale, which is exactly the coverage gap the
///     product beats.
///   - Using it would require the `NSSpeechRecognitionUsageDescription` Info.plist
///     key + a speech-recognition authorization prompt. The rest of the app never
///     touches `SFSpeechRecognizer` (ARCHITECTURE §7: "No speech-recognition
///     entitlement"), so this engine is compiled but only reachable from the debug
///     Engine Lab, behind an explicit authorization request.
///
/// Conforms to the upstream `FileTranscriptionEngine` seam (WAV in → text out via
/// callbacks) so the Engine Lab drives it identically to the Parakeet/WhisperKit
/// file engines. `SFSpeechURLRecognitionRequest` handles file recognition directly.
public final class AppleSpeechBaselineEngine: FileTranscriptionEngine {
    public var onTranscriptionComplete: ((UUID, String) -> Void)?
    public var onTranscriptionError: ((UUID, String) -> Void)?
    public var onProgress: ((Int) -> Void)?
    public var onWorkerStatus: ((String) -> Void)?

    /// BCP-47 locale for the recognizer, e.g. "en-US", "ru-RU". The Engine Lab
    /// picks this to match the fixture's reference language; "auto" is not a thing
    /// for `SFSpeechRecognizer` (it is single-locale), which is itself part of the
    /// baseline story.
    private let localeIdentifier: String

    public init(localeIdentifier: String = "en-US") {
        self.localeIdentifier = localeIdentifier
    }

    /// Request speech authorization (the Engine Lab calls this before first use).
    /// Kept static + explicit so no other code path can silently trigger the prompt.
    public static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    public var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    // No warm server / persistent model — recognition is per-request.
    public func warmServer(binaryPath: String, modelPath: String) {}
    public func stopServer() {}

    public func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        backend: WhisperBackend,
        prompt: String
    ) {
        // Honor a fixed language from the caller; fall back to the configured
        // locale. "auto"/"" → configured locale (SFSpeechRecognizer is single-locale).
        let localeID = (language.isEmpty || language == "auto") ? localeIdentifier : language
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            finishError(requestID, "No Apple Speech recognizer for locale \"\(localeID)\".",
                        wavPath: wavPath, deleteWhenDone: deleteWhenDone)
            return
        }
        guard recognizer.isAvailable else {
            finishError(requestID, "Apple Speech recognizer is unavailable right now.",
                        wavPath: wavPath, deleteWhenDone: deleteWhenDone)
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // The baseline is ONLY meaningful on-device (local-first). If Apple has
            // no on-device model for this locale, that's a real data point — the
            // baseline simply can't run here.
            finishError(requestID,
                        "Apple Speech has no on-device model for \"\(localeID)\" (baseline can't run on-device here).",
                        wavPath: wavPath, deleteWhenDone: deleteWhenDone)
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: URL(fileURLWithPath: wavPath))
        request.requiresOnDeviceRecognition = true    // local-first, never a server
        request.shouldReportPartialResults = false

        // Guard so we deliver exactly one result/error per request even though the
        // recognition callback can fire multiple times.
        let delivered = DeliveryGuard()
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error {
                guard delivered.claim() else { return }
                self.finishError(requestID, "Apple Speech failed: \(error.localizedDescription)",
                                 wavPath: wavPath, deleteWhenDone: deleteWhenDone)
                return
            }
            guard let result, result.isFinal else { return }
            guard delivered.claim() else { return }
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
            self.onTranscriptionComplete?(requestID, text)
        }
    }

    private func finishError(_ id: UUID, _ message: String, wavPath: String, deleteWhenDone: Bool) {
        if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
        onTranscriptionError?(id, message)
    }
}

/// One-shot claim so a multi-fire recognition callback delivers exactly once.
private final class DeliveryGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
