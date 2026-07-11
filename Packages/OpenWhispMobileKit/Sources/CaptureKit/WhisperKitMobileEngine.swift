import Foundation
import OpenWhispCore

/// WhisperKit streaming engine for iOS — the SECONDARY engine (ARCHITECTURE D5),
/// covering the ~100-language long tail Parakeet's streaming variants don't.
/// Conforms to the upstream `StreamingTranscriptionEngine` seam; `AudioStreamTranscriber`
/// owns the mic and runs its own energy VAD (silence is skipped).
///
/// Ported from the mac `WhisperKitStreamingEngine`, dropping the `#if WHISPERKIT`
/// guard (WhisperKit is always linked on iOS) and the CoreAudio device routing
/// (AVAudioSession governs input). iOS-suitable models: tiny / base / small.
public final class WhisperKitMobileEngine: StreamingTranscriptionEngine {
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    public var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?

    private let modelName: String

    public func selectDevice(_ deviceID: String) {
        // iOS: AVAudioSession governs input; no CoreAudio device to pin. No-op.
    }

    public init(modelName: String = "openai_whisper-small") {
        self.modelName = modelName
    }

    private var loadedKit: WhisperKitHandle?
    @MainActor private var inFlightLoad: Task<WhisperKitHandle, Error>?
    @MainActor private var transcriber: WhisperKitStreamHandle?
    @MainActor private var lastConfirmedText: String = ""
    @MainActor private var didFinish: Bool = false
    @MainActor private var generation = 0
    @MainActor private let lifecycle = SerialTaskChain()

    public func start(language: String) throws {
        let task = WhisperKitTaskMapper.map(languageSetting: language)
        MainActor.assumeIsolated {
            self.lastConfirmedText = ""
            self.didFinish = false
            self.lifecycle.enqueue {
                await self.runStart(task: task)
            }
        }
    }

    @MainActor
    private func runStart(task: WhisperKitTaskMapper.Resolved) async {
        do {
            let kit = try await ensureLoaded()
            generation += 1
            let myGeneration = generation
            let handle = try WhisperKitMobileBridge.makeStreamHandle(
                kit: kit,
                task: task,
                languageOverride: nil
            ) { [weak self] newState in
                Task { @MainActor in
                    guard let self, self.generation == myGeneration else { return }
                    self.handleState(newState)
                }
            }
            transcriber = handle
            Task { @MainActor [weak self] in
                do {
                    try await handle.start()
                } catch {
                    NSLog("[WhisperKitStream] stream error: %@", error.localizedDescription)
                    guard let self, self.transcriber === handle, !self.didFinish else { return }
                    self.onError?("WhisperKit streaming failed: \(error.localizedDescription)")
                }
            }
        } catch {
            NSLog("[WhisperKitStream] start error: %@", error.localizedDescription)
            guard !didFinish else { return }
            onError?("WhisperKit streaming failed: \(error.localizedDescription)")
        }
    }

    public func stop(cancel: Bool) {
        MainActor.assumeIsolated {
            self.lifecycle.enqueue {
                await self.runStop(cancel: cancel)
            }
        }
    }

    @MainActor
    private func runStop(cancel: Bool) async {
        let handle = transcriber
        transcriber = nil
        didFinish = true
        generation += 1
        await handle?.stop()
        if !cancel {
            let full = await handle?.finalizeTail() ?? handle?.fullText() ?? ""
            let final = full.isEmpty ? lastConfirmedText : full
            onFinal?(final.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @MainActor
    private func handleState(_ state: WhisperKitStreamState) {
        if let level = state.peakRelativeEnergy {
            onLevelChanged?(level, state.vadLevel ?? level)
        }
        let text = state.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastConfirmedText else { return }
        lastConfirmedText = text
        onPartial?(text)
    }

    @discardableResult
    private func ensureLoaded() async throws -> WhisperKitHandle {
        if let kit = loadedKit { return kit }
        let task = await loadTaskOnMain()
        do {
            let kit = try await task.value
            loadedKit = kit
            return kit
        } catch {
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor
    private func clearFailedLoad(_ failed: Task<WhisperKitHandle, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    @MainActor
    private func loadTaskOnMain() -> Task<WhisperKitHandle, Error> {
        if let existing = inFlightLoad { return existing }
        let name = modelName
        let task = Task<WhisperKitHandle, Error> {
            NSLog("[WhisperKitStream] loading model '%@'…", name)
            let kit = try await WhisperKitMobileBridge.load(model: name)
            NSLog("[WhisperKitStream] model loaded.")
            return kit
        }
        inFlightLoad = task
        return task
    }
}

/// WhisperKit file engine for iOS — the secondary batch/fixture path. Conforms to
/// the upstream `FileTranscriptionEngine` seam. Ported from the mac `WhisperKitEngine`,
/// dropping the `#if WHISPERKIT` guard and `Instrumentation`.
public final class WhisperKitMobileFileEngine: FileTranscriptionEngine {
    public var onTranscriptionComplete: ((UUID, String) -> Void)?
    public var onTranscriptionError: ((UUID, String) -> Void)?
    public var onProgress: ((Int) -> Void)?
    public var onWorkerStatus: ((String) -> Void)?

    private let modelName: String

    public init(modelName: String = "openai_whisper-small") {
        self.modelName = modelName
    }

    @MainActor private var loadedKit: WhisperKitHandle?
    @MainActor private var inFlightLoad: Task<WhisperKitHandle, Error>?
    @MainActor private var loadGeneration = 0
    @MainActor private var stickyLanguage: String?
    @MainActor private var inFlightDetect: Task<String, Error>?

    /// Download + stage a WhisperKit model (for the model manager / provisioning).
    public static func downloadModel(_ model: String, onProgress: @escaping (Double) -> Void) async throws {
        try await WhisperKitMobileBridge.downloadModel(model, onProgress: onProgress)
    }

    public func warmServer(binaryPath: String, modelPath: String) {
        Task { try? await self.ensureLoaded() }
    }

    public func stopServer() {
        Task { @MainActor in
            self.inFlightLoad?.cancel()
            self.inFlightLoad = nil
            self.loadedKit = nil
            self.loadGeneration += 1
            self.stickyLanguage = nil
            self.inFlightDetect = nil
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
                let kit = try await self.ensureLoaded()
                let task = WhisperKitTaskMapper.map(languageSetting: language)
                var override: String? = nil
                if task.language == nil && !task.translate {
                    override = try await self.stickyAutoLanguage(kit: kit, wavPath: wavPath)
                }
                let text = try await WhisperKitMobileBridge.transcribe(
                    kit: kit, wavPath: wavPath, task: task, languageOverride: override, prompt: prompt
                )
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run { self.onTranscriptionComplete?(requestID, text) }
            } catch {
                NSLog("[WhisperKit] transcription failed: %@", error.localizedDescription)
                if deleteWhenDone { try? FileManager.default.removeItem(atPath: wavPath) }
                await MainActor.run {
                    self.onTranscriptionError?(requestID, "WhisperKit failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func resetSession() {
        Task { @MainActor in
            self.stickyLanguage = nil
            self.inFlightDetect = nil
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> WhisperKitHandle {
        let (generation, task) = await loadTaskOnMain()
        do {
            let kit = try await task.value
            await storeLoadedKit(kit, generation: generation)
            return kit
        } catch {
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor
    private func storeLoadedKit(_ kit: WhisperKitHandle, generation: Int) {
        guard generation == loadGeneration else { return }
        loadedKit = kit
    }

    @MainActor
    private func clearFailedLoad(_ failed: Task<WhisperKitHandle, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    @MainActor
    private func loadTaskOnMain() -> (generation: Int, task: Task<WhisperKitHandle, Error>) {
        if let kit = loadedKit { return (loadGeneration, Task<WhisperKitHandle, Error> { kit }) }
        if let existing = inFlightLoad { return (loadGeneration, existing) }
        let name = modelName
        let status = onWorkerStatus
        let task = Task<WhisperKitHandle, Error> {
            NSLog("[WhisperKit] loading model '%@'…", name)
            await MainActor.run { status?("Preparing WhisperKit model…") }
            let kit = try await WhisperKitMobileBridge.load(model: name)
            NSLog("[WhisperKit] model loaded.")
            await MainActor.run { status?("WhisperKit ready") }
            return kit
        }
        inFlightLoad = task
        return (loadGeneration, task)
    }

    private func stickyAutoLanguage(kit: WhisperKitHandle, wavPath: String) async throws -> String {
        let task = await detectTaskOnMain(kit: kit, wavPath: wavPath)
        let lang = try await task.value
        await MainActor.run { self.stickyLanguage = lang }
        return lang
    }

    @MainActor
    private func detectTaskOnMain(kit: WhisperKitHandle, wavPath: String) -> Task<String, Error> {
        if let cached = stickyLanguage { return Task { cached } }
        if let existing = inFlightDetect { return existing }
        let task = Task<String, Error> {
            try await WhisperKitMobileBridge.detectLanguage(kit: kit, wavPath: wavPath)
        }
        inFlightDetect = task
        return task
    }
}
