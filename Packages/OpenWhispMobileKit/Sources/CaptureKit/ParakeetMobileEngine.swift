import Foundation
import AVFoundation
import OpenWhispCore

/// True-streaming Parakeet engine for iOS — the PRIMARY engine (ARCHITECTURE D5):
/// NVIDIA Parakeet on CoreML via FluidAudio's cache-aware streaming managers.
/// Partials trail the voice by the variant's chunk latency, which is what makes
/// dictation feel realtime.
///
/// Conforms to the upstream `StreamingTranscriptionEngine` seam: it owns the
/// microphone via its own `AVAudioEngine` tap, feeds buffers to FluidAudio, and
/// emits the growing transcript through `onPartial`.
///
/// Ported from the mac `ParakeetStreamingEngine`. iOS deltas:
///   - No `AudioInputRoutingPolicy` / CoreAudio device pinning: iOS routes input
///     via `AVAudioSession`, so `selectDevice` is a documented no-op. The engine
///     assumes the session is already configured (`.playAndRecord`, `.measurement`)
///     by the coordinator before `start()`.
///   - `#if PARAKEET` dropped: FluidAudio is always linked on iOS.
///   - `SerialTaskChain` / level math ported locally (upstream keeps them internal).
public final class ParakeetMobileEngine: StreamingTranscriptionEngine {
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    public var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)?

    /// Fires when the underlying manager reports a NEW end-of-utterance event (only
    /// the EOU variant exposes these). Used by the agent-dictate EOU auto-stop; nil
    /// for every other caller. Fires on the main actor.
    public var onEouDetected: (() -> Void)?

    /// `ParakeetCatalog` variant id.
    private let variantID: String

    public func selectDevice(_ deviceID: String) {
        // iOS routes input via AVAudioSession.preferredInput; no CoreAudio UID.
        // Documented no-op (mac pins a device here).
    }

    public init(variantID: String = ParakeetCatalog.defaultVariantID) {
        self.variantID = ParakeetCatalog.normalize(variantID)
    }

    // AVAudioEngine + FluidAudio session handles. Main-actor confined.
    @MainActor private var audioEngine: AVAudioEngine?
    @MainActor private var session: (any ParakeetStreamSession)?
    @MainActor private var inFlightLoad: Task<any ParakeetStreamSession, Error>?
    @MainActor private var feedContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    @MainActor private var feedTask: Task<Void, Never>?

    @MainActor private var lastPartial = ""
    @MainActor private var lastEouCount = 0
    @MainActor private var didStop = false
    @MainActor private var generation = 0
    @MainActor private let lifecycle = SerialTaskChain()

    public func start(language: String) throws {
        MainActor.assumeIsolated {
            self.lastPartial = ""
            self.lastEouCount = 0
            self.didStop = false
            self.lifecycle.enqueue {
                await self.runStart(language: language)
            }
        }
    }

    @MainActor
    private func runStart(language: String) async {
        do {
            // Variant-aware language gate: English-only variants refuse a FIXED
            // non-English language up front (never silently mangle it); the
            // multilingual variant accepts any language ("auto" for unknowns).
            if let message = ParakeetLanguageGate.refusalMessage(
                languageSetting: language,
                multilingual: ParakeetCatalog.isMultilingual(variantID)
            ) {
                onError?(message)
                return
            }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // 0 Hz / 0 ch (no input) would make installTap raise an ObjC NSException
            // Swift can't catch — guard it out.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                onError?("No audio input device available.")
                return
            }

            let session = try await ensureLoaded()
            try await session.reset()
            await session.setLanguage(ParakeetLanguageHint.multilingualLanguageCode(from: language))

            generation += 1
            let myGeneration = generation

            await session.setPartialCallback { [weak self] text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == myGeneration else { return }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != self.lastPartial else { return }
                        self.lastPartial = trimmed
                        self.onPartial?(trimmed)
                    }
                }
            }

            let (stream, continuation) = AsyncStream.makeStream(
                of: AVAudioPCMBuffer.self,
                bufferingPolicy: .unbounded
            )
            feedContinuation = continuation
            let pollsEou = ParakeetCatalog.emitsEou(variantID)
            feedTask = Task { [weak self] in
                do {
                    for await buffer in stream {
                        try await session.appendAudio(buffer)
                        try await session.processBuffered()
                        if pollsEou {
                            let count = await session.eouTimestampsMs().count
                            await MainActor.run { [weak self] in
                                guard let self, self.generation == myGeneration, !self.didStop else { return }
                                if count > self.lastEouCount {
                                    self.lastEouCount = count
                                    self.onEouDetected?()
                                }
                            }
                        }
                    }
                } catch {
                    NSLog("[Parakeet] stream feed error: %@", error.localizedDescription)
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == myGeneration, !self.didStop else { return }
                        self.onError?("Parakeet streaming failed: \(error.localizedDescription)")
                    }
                }
            }

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.feedBuffer(buffer)
                self?.publishLevel(from: buffer)
            }

            audioEngine = engine
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("[Parakeet] start error: %@", error.localizedDescription)
            guard !didStop else { return }
            onError?("Parakeet streaming failed: \(error.localizedDescription)")
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
        didStop = true
        generation += 1

        if let audioEngine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        audioEngine = nil

        feedContinuation?.finish()
        feedContinuation = nil
        await feedTask?.value
        feedTask = nil

        guard let session else { return }
        if cancel {
            try? await session.reset()
            return
        }
        do {
            let final = try await session.finish()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            onFinal?(final.isEmpty ? lastPartial : final)
        } catch {
            NSLog("[Parakeet] finish error: %@", error.localizedDescription)
            onFinal?(lastPartial)
        }
    }

    /// Load/download the variant's model and return when it's staged (or the load
    /// failed). Idempotent; joins an in-flight load / returns immediately when cached.
    @MainActor
    public func prefetchAwaiting() async {
        _ = try? await loadTaskOnMain().value
    }

    private nonisolated func feedBuffer(_ buffer: AVAudioPCMBuffer) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.feedContinuation?.yield(buffer)
            }
        }
    }

    @discardableResult
    private func ensureLoaded() async throws -> any ParakeetStreamSession {
        if let session = await currentSession() { return session }
        let task = await loadTaskOnMain()
        do {
            let session = try await task.value
            await storeSession(session)
            return session
        } catch {
            await clearFailedLoad(task)
            throw error
        }
    }

    @MainActor private func currentSession() -> (any ParakeetStreamSession)? { session }
    @MainActor private func storeSession(_ s: any ParakeetStreamSession) { session = s }

    @MainActor
    private func clearFailedLoad(_ failed: Task<any ParakeetStreamSession, Error>) {
        if inFlightLoad == failed { inFlightLoad = nil }
    }

    @MainActor
    private func loadTaskOnMain() -> Task<any ParakeetStreamSession, Error> {
        if let existing = inFlightLoad { return existing }
        let variant = variantID
        let task = Task<any ParakeetStreamSession, Error> {
            NSLog("[Parakeet] loading variant '%@'…", variant)
            let session = try await ParakeetBridge.loadStreamSession(variantID: variant)
            NSLog("[Parakeet] variant loaded.")
            return session
        }
        inFlightLoad = task
        return task
    }

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                sum += samples[frame] * samples[frame]
            }
        }
        let rms = sqrt(sum / Float(max(1, channelCount * frameCount)))
        // fromRMS is the absolute curve, so display and VAD levels coincide.
        let normalized = AudioLevelMath.fromRMS(rms)
        DispatchQueue.main.async {
            self.onLevelChanged?(normalized, normalized)
        }
    }
}
