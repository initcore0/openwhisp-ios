import Foundation
import WhisperKit
import CoreML
import OpenWhispCore

// MARK: - iOS WhisperKit bridge
//
// The mac `WhisperKitBridge` is `internal` and macOS-shaped (imports CoreAudio,
// pins the audio encoder to the GPU to dodge a macOS-26 ANE stall, threads a
// CoreAudio `AudioDeviceID`). We build an iOS-native equivalent here, reusing the
// PUBLIC pure types from OpenWhispCore — `WhisperKitTaskMapper` (language/translate
// mapping, incl. the translate sentinel) and `WhisperKitModelCatalog` (staging
// identity + paths). Everything WhisperKit-specific lives in this one file.
//
// iOS deltas vs mac:
//   - No CoreAudio import; `DeviceID` is `String` on iOS. We do not pin an input
//     device (AVAudioSession governs input) — `inputDeviceID` stays nil.
//   - We leave `computeOptions` unset so WhisperKit defaults the audio encoder to
//     `.cpuAndNeuralEngine` — on iOS the ANE is the whole point (efficiency), and
//     the macOS-26 ANE-stall that forced the mac's `.cpuAndGPU` pin doesn't apply.

/// Small local timeout helper (upstream `withTimeout` is internal). Races the
/// operation against a sleep; whichever finishes first wins, the loser is cancelled.
func withEngineTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw WhisperKitMobileError.timedOut(seconds)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

typealias WhisperKitHandle = WhisperKit

enum WhisperKitMobileBridge {
    static let stagedLoadTimeout: Double = 120
    static let downloadLoadTimeout: Double = 600

    /// Keep every WhisperKit cache (tokenizer/config fetches, auto-downloaded
    /// models) under our Application Support dir. Reuses the catalog's hub path.
    static func hubDownloadBase() -> URL {
        let dir = WhisperKitModelCatalog.hubBaseDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Compiled model folder for a staged model, or nil (caller falls back to
    /// WhisperKit's auto-download path).
    static func compiledModelFolder(for model: String) -> URL? {
        guard WhisperKitModelCatalog.isStaged(model) else { return nil }
        return WhisperKitModelCatalog.baseDir.appendingPathComponent(model, isDirectory: true)
    }

    static func load(model: String) async throws -> WhisperKit {
        try Task.checkCancellation()
        if let folder = compiledModelFolder(for: model) {
            return try await withEngineTimeout(seconds: stagedLoadTimeout) {
                let config = WhisperKitConfig(
                    downloadBase: hubDownloadBase(),
                    modelFolder: folder.path
                )
                return try await WhisperKit(config)
            }
        }
        return try await withEngineTimeout(seconds: downloadLoadTimeout) {
            let config = WhisperKitConfig(
                model: model,
                downloadBase: hubDownloadBase()
            )
            return try await WhisperKit(config)
        }
    }

    /// Download `model` from the WhisperKit CoreML repo and STAGE it flat under
    /// `baseDir/<model>` (the layout `compiledModelFolder` expects), reporting 0…1
    /// progress. Same staging discipline as the mac bridge.
    static func downloadModel(
        _ model: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let baseDir = WhisperKitModelCatalog.baseDir
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let tempBase = fm.temporaryDirectory
            .appendingPathComponent("openwhisp-wk-download-\(model)", isDirectory: true)
        try? fm.removeItem(at: tempBase)
        try fm.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempBase) }

        let downloaded = try await WhisperKit.download(
            variant: model,
            downloadBase: tempBase
        ) { progress in
            let total = progress.totalUnitCount
            let fraction = total > 0 ? Double(progress.completedUnitCount) / Double(total) : 0
            onProgress(max(0, min(1, fraction)))
        }

        let ok = WhisperKitModelCatalog.requiredSubmodels.allSatisfy {
            fm.fileExists(atPath: downloaded.appendingPathComponent($0).path)
        }
        guard ok else { throw WhisperKitMobileError.incompleteDownload(model) }

        let dest = baseDir.appendingPathComponent(model, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: downloaded, to: dest)
        onProgress(1)
    }

    /// Detect the spoken language of a WAV file (Whisper code, e.g. "ru"). Used to
    /// pin the language once per "auto" session rather than flap per chunk.
    static func detectLanguage(kit: WhisperKit, wavPath: String) async throws -> String {
        let (language, _) = try await kit.detectLanguage(audioPath: wavPath)
        return language
    }

    /// Transcribe a WAV file to plain text, honoring the language/translate task.
    static func transcribe(
        kit: WhisperKit,
        wavPath: String,
        task: WhisperKitTaskMapper.Resolved,
        languageOverride: String? = nil,
        prompt: String
    ) async throws -> String {
        let options = DecodingOptions(
            task: task.translate ? .translate : .transcribe,
            language: languageOverride ?? task.language
        )
        let results = try await kit.transcribe(audioPath: wavPath, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Construct a streaming handle from an already-loaded WhisperKit, wrapping
    /// `AudioStreamTranscriber` (which owns the mic + its own energy VAD). Language:
    /// explicit is pinned; "auto" turns on `detectLanguage` so non-English speech
    /// isn't forced to English.
    static func makeStreamHandle(
        kit: WhisperKit,
        task: WhisperKitTaskMapper.Resolved,
        languageOverride: String?,
        onState: @escaping (WhisperKitStreamState) -> Void
    ) throws -> WhisperKitStreamHandle {
        guard let tokenizer = kit.tokenizer else {
            throw WhisperKitMobileError.tokenizerUnavailable
        }
        let resolvedLanguage = languageOverride ?? task.language
        let autoDetect = resolvedLanguage == nil && !task.translate
        let options = DecodingOptions(
            task: task.translate ? .translate : .transcribe,
            language: resolvedLanguage,
            detectLanguage: autoDetect,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let handle = WhisperKitStreamHandle(kit: kit, decodingOptions: options)
        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options,
            useVAD: true,
            inputDeviceID: nil,   // iOS: AVAudioSession governs input; no device pinning
            stateChangeCallback: { _, new in
                // Absolute-scale level for the VAD: `audioEnergy.avg` is the raw
                // per-buffer RMS; `AudioLevelMath.fromRMS` puts it on the same
                // absolute dB curve the recorder feeds the silence detector.
                let absoluteRMS = (kit.audioProcessor as? AudioProcessor)?.audioEnergy.last?.avg
                let snapshot = WhisperKitStreamState(
                    from: new,
                    vadLevel: absoluteRMS.map { AudioLevelMath.fromRMS($0) }
                )
                handle.latest = snapshot
                onState(snapshot)
            }
        )
        handle.attach(transcriber)
        return handle
    }
}

/// Plain-Swift snapshot of the streaming state — keeps WhisperKit types out of the
/// engine. Ported from the mac `WhisperKitStreamState`, minus the relative-energy
/// live-level helper (that used the internal `AudioLevel.liveLevel`; here the
/// waveform reads `peakRelativeEnergy` directly and the coordinator maps it).
struct WhisperKitStreamState {
    let confirmedText: String
    let fullText: String
    /// Most recent relative mic energy (0…1) for the waveform.
    let peakRelativeEnergy: Float?
    /// Absolute-curve level for the silence auto-stop.
    let vadLevel: Float?
    let decodedSampleCount: Int
    let confirmedEndSeconds: Float

    init(from state: AudioStreamTranscriber.State, vadLevel: Float?) {
        let confirmed = state.confirmedSegments.map(\.text).joined(separator: " ")
        let unconfirmed = state.unconfirmedSegments.map(\.text).joined(separator: " ")
        self.confirmedText = confirmed
        self.fullText = (confirmed + " " + unconfirmed)
        self.decodedSampleCount = state.lastBufferSize
        self.confirmedEndSeconds = state.lastConfirmedSegmentEndSeconds
        // `bufferEnergy` is the cumulative per-buffer relative-energy history; read
        // the RECENT window (not the all-time max, which freezes the bars).
        self.peakRelativeEnergy = state.bufferEnergy.suffix(3).max()
        self.vadLevel = vadLevel
    }
}

/// Lifecycle wrapper around `AudioStreamTranscriber`. Ported from the mac
/// `WhisperKitStreamHandle`.
final class WhisperKitStreamHandle {
    private var transcriber: AudioStreamTranscriber?
    private let kit: WhisperKit
    private let decodingOptions: DecodingOptions

    init(kit: WhisperKit, decodingOptions: DecodingOptions) {
        self.kit = kit
        self.decodingOptions = decodingOptions
    }

    private let latestLock = NSLock()
    private var latestStorage: WhisperKitStreamState?
    var latest: WhisperKitStreamState? {
        get { latestLock.lock(); defer { latestLock.unlock() }; return latestStorage }
        set { latestLock.lock(); defer { latestLock.unlock() }; latestStorage = newValue }
    }

    func attach(_ transcriber: AudioStreamTranscriber) { self.transcriber = transcriber }

    func start() async throws { try await transcriber?.startStreamTranscription() }
    func stop() async { await transcriber?.stopStreamTranscription() }

    func fullText() -> String {
        (latest?.fullText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let minFlushSamples = 4_000

    /// Decode any audio captured after the realtime loop's last window (a quick
    /// stop strands the trailing words). nil = everything was already decoded.
    func finalizeTail() async -> String? {
        let snapshot = latest
        let samples = Array(kit.audioProcessor.audioSamples)
        let decoded = snapshot?.decodedSampleCount ?? 0
        guard samples.count > decoded + Self.minFlushSamples else { return nil }

        var options = decodingOptions
        options.clipTimestamps = [snapshot?.confirmedEndSeconds ?? 0]
        let kit = self.kit
        guard let results = try? await withEngineTimeout(seconds: 15, operation: {
            try await kit.transcribe(audioArray: samples, decodeOptions: options)
        }) else { return nil }

        let tail = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = (snapshot?.confirmedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let full = (confirmed + " " + tail).trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? nil : full
    }
}

enum WhisperKitMobileError: Error, LocalizedError {
    case tokenizerUnavailable
    case incompleteDownload(String)
    case timedOut(Double)
    var errorDescription: String? {
        switch self {
        case .tokenizerUnavailable:
            return "WhisperKit tokenizer not loaded (model may still be loading)."
        case .incompleteDownload(let model):
            return "Downloaded model \"\(model)\" is missing required files."
        case .timedOut(let seconds):
            return "WhisperKit operation timed out after \(Int(seconds))s."
        }
    }
}
