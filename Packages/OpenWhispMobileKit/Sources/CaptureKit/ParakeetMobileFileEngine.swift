import Foundation
import OpenWhispCore

/// Parakeet-backed `FileTranscriptionEngine` for iOS — the BATCH / file path:
/// NVIDIA Parakeet TDT v3 on CoreML via FluidAudio's batch `AsrManager`. Covers
/// fixture/benchmark WAV runs, and (later) any non-live iOS path.
///
/// Live *dictation* stays on `ParakeetMobileEngine` (true streaming is the point).
/// TDT v3 covers 25 European languages (incl. Russian), so — unlike the
/// English-only streaming variants — the file path is genuinely multilingual.
///
/// The whisper-specific `binaryPath`/`modelPath`/`backend`/`prompt` params are
/// ignored (TDT v3 is a single on-device CoreML model). Language is honored as a
/// v3 script hint when a fixed language is set; "auto" lets the model decide.
///
/// Ported from the mac `ParakeetFileEngine`, dropping the `#if PARAKEET` guard and
/// the `Instrumentation` calls (mac-only). FluidAudio is always linked on iOS.
public final class ParakeetMobileFileEngine: FileTranscriptionEngine {
    public var onTranscriptionComplete: ((UUID, String) -> Void)?
    public var onTranscriptionError: ((UUID, String) -> Void)?
    public var onProgress: ((Int) -> Void)?
    public var onWorkerStatus: ((String) -> Void)?

    public init() {}

    // Single shared load Task, observed on the main actor so concurrent requests
    // coalesce onto ONE download+load.
    @MainActor private var loadedHandle: ParakeetBridge.BatchHandle?
    @MainActor private var inFlightLoad: Task<ParakeetBridge.BatchHandle, Error>?
    /// Bumped by stopServer(): a load begun before a stop must not repopulate the
    /// cached handle when it completes.
    @MainActor private var loadGeneration = 0

    public func warmServer(binaryPath: String, modelPath: String) {
        // No external server; warm = preload the CoreML model.
        Task { try? await self.ensureLoaded() }
    }

    public func stopServer() {
        Task { @MainActor in
            self.inFlightLoad?.cancel()
            self.inFlightLoad = nil
            self.loadedHandle = nil
            self.loadGeneration += 1
        }
    }

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
        Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try await self.ensureLoaded()
                let languageCode = ParakeetLanguageHint.batchLanguageCode(from: language)
                let text = try await ParakeetBridge.transcribeBatch(
                    handle: handle,
                    wavURL: URL(fileURLWithPath: wavPath),
                    languageCode: languageCode
                )
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run { self.onTranscriptionComplete?(requestID, text) }
            } catch {
                NSLog("[Parakeet] file transcription failed: %@", error.localizedDescription)
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run {
                    self.onTranscriptionError?(requestID, "Parakeet failed: \(error.localizedDescription)")
                }
            }
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> ParakeetBridge.BatchHandle {
        let (generation, task) = await loadTaskOnMain()
        do {
            let handle = try await task.value
            await storeHandle(handle, generation: generation)
            return handle
        } catch {
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor
    private func storeHandle(_ handle: ParakeetBridge.BatchHandle, generation: Int) {
        guard generation == loadGeneration else { return }
        loadedHandle = handle
    }

    @MainActor
    private func clearFailedLoad(_ failed: Task<ParakeetBridge.BatchHandle, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    @MainActor
    private func loadTaskOnMain() -> (generation: Int, task: Task<ParakeetBridge.BatchHandle, Error>) {
        if let handle = loadedHandle { return (loadGeneration, Task { handle }) }
        if let existing = inFlightLoad { return (loadGeneration, existing) }
        let status = onWorkerStatus
        let task = Task<ParakeetBridge.BatchHandle, Error> {
            NSLog("[Parakeet] loading TDT v3 batch model…")
            await MainActor.run { status?("Preparing Parakeet model…") }
            let handle = try await ParakeetBridge.loadBatch()
            NSLog("[Parakeet] TDT v3 batch model loaded.")
            await MainActor.run { status?("Parakeet ready") }
            return handle
        }
        inFlightLoad = task
        return (loadGeneration, task)
    }
}
