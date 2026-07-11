import Foundation
import AVFoundation
import MobileCore
import OpenWhispCore
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Engine Lab runner (WP3) — the Goal-#1 measurement engine
//
// Drives a fixture WAV through ANY installed engine via the upstream
// `FileTranscriptionEngine` seam (Parakeet TDT v3 / WhisperKit file / Apple
// baseline), measures latency + realtime factor + peak-RSS delta, scores WER
// against the fixture's reference, and returns a pure `MobileCore.LabRun` record.
//
// It lives in CaptureKit because it touches the OS: `AVAudioFile` for audio
// duration, `task_info` for RSS, and it constructs the concrete engines. The
// SCORING and the record shape are pure MobileCore (tested on the gate); this file
// is the thin OS-bound orchestration around them.

/// Which engine + variant the Lab should run.
public enum LabEngineSelection: Equatable, Sendable {
    /// A Parakeet variant id from `ParakeetCatalog` (e.g. "nemotron-multilingual-1120ms").
    case parakeet(variantID: String)
    /// A WhisperKit model id (e.g. "openai_whisper-tiny.en").
    case whisperKit(modelID: String)
    /// The Apple on-device baseline for a BCP-47 locale (benchmark only).
    case appleBaseline(locale: String)

    public var kind: LabEngineKind {
        switch self {
        case .parakeet: return .parakeet
        case .whisperKit: return .whisperKit
        case .appleBaseline: return .appleBaseline
        }
    }

    public var modelID: String {
        switch self {
        case .parakeet(let v): return v
        case .whisperKit(let m): return m
        case .appleBaseline(let l): return "apple:\(l)"
        }
    }

    /// Human-readable engine name for the run record + UI.
    public var displayName: String {
        switch self {
        case .parakeet(let v): return ParakeetCatalog.variant(for: v).name
        case .whisperKit(let m): return "WhisperKit — \(WhisperKitModelCatalog.displayInfo(for: m).label)"
        case .appleBaseline(let l): return "Apple Speech (\(l))"
        }
    }
}

/// Runs fixtures/live audio through engines and produces `LabRun` records.
@MainActor
public final class LabRunner {
    public init() {}

    /// Build a fresh `FileTranscriptionEngine` for a selection. A fresh instance per
    /// run keeps memory measurement honest (no warm cache from a prior run) and lets
    /// compare-mode run two engines independently.
    public func makeFileEngine(for selection: LabEngineSelection) -> FileTranscriptionEngine {
        switch selection {
        case .parakeet:
            // The Parakeet file path is TDT v3 (multilingual batch); the streaming
            // variant id only picks the LANGUAGE hint, not a separate file model.
            return ParakeetMobileFileEngine()
        case .whisperKit(let modelID):
            return WhisperKitMobileFileEngine(modelName: modelID)
        case .appleBaseline(let locale):
            return AppleSpeechBaselineEngine(localeIdentifier: locale)
        }
    }

    /// Run a fixture through a selected engine and return a scored `LabRun`.
    ///
    /// - Parameters:
    ///   - fixture: which bundled fixture (drives reference + language default).
    ///   - wavURL: the resolved on-disk WAV (the host app copies it out of the bundle).
    ///   - reference: the fixture's reference transcript ("" for silence/live).
    ///   - selection: engine + variant.
    ///   - language: language hint passed to the engine ("auto" or a code).
    public func run(
        fixture: LabFixture,
        wavURL: URL,
        reference: String,
        selection: LabEngineSelection,
        language: String
    ) async -> LabRun {
        let engine = makeFileEngine(for: selection)
        let audioSeconds = Self.audioDuration(of: wavURL)

        // Work on a COPY: the engines delete the WAV when deleteWhenDone is true, and
        // the bundle copy must survive for the next run/engine.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lab-\(UUID().uuidString).wav")
        let rssBefore = Self.residentSizeBytes()
        let start = Date()

        var hypothesis = ""
        var errorMessage: String?
        do {
            try FileManager.default.copyItem(at: wavURL, to: temp)
            hypothesis = try await transcribe(engine: engine, wavPath: temp.path, language: language)
        } catch let caught {
            errorMessage = (caught as? LabTranscribeError)?.message ?? caught.localizedDescription
        }
        let latency = Date().timeIntervalSince(start)
        let rssAfter = Self.residentSizeBytes()
        let rssDelta = max(0, rssAfter - rssBefore)

        // Score only when we have a reference AND no error.
        let wer: Double? = {
            guard errorMessage == nil, !reference.isEmpty || fixture.isSilence else { return nil }
            return WordErrorRate.score(reference: reference, hypothesis: hypothesis).wer
        }()

        return LabRun(
            date: start,
            engineName: selection.displayName,
            engineKind: selection.kind,
            modelID: selection.modelID,
            fixtureName: fixture.name,
            isLive: false,
            language: language,
            reference: reference,
            hypothesis: hypothesis,
            wer: wer,
            metrics: LabMetrics(
                latencySeconds: latency,
                audioSeconds: audioSeconds,
                peakRSSDeltaBytes: rssDelta
            ),
            error: errorMessage
        )
    }

    // MARK: - Callback → async bridge

    private func transcribe(
        engine: FileTranscriptionEngine, wavPath: String, language: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let box = ResumeOnceBox(continuation)
            engine.onTranscriptionComplete = { rid, text in
                guard rid == id else { return }
                box.resume(returning: text)
            }
            engine.onTranscriptionError = { rid, message in
                guard rid == id else { return }
                box.resume(throwing: LabTranscribeError(message: message))
            }
            engine.transcribe(
                requestID: id, binaryPath: "", modelPath: "", language: language,
                wavPath: wavPath, deleteWhenDone: true, backend: .cli, prompt: ""
            )
        }
    }

    // MARK: - OS measurements

    /// Duration of a WAV in seconds via `AVAudioFile` (0 on failure).
    nonisolated static func audioDuration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    /// Current resident memory in bytes (best-effort; 0 if unavailable). Used to
    /// derive the peak-RSS DELTA across a run. Not a true peak sampler — a
    /// before/after phys_footprint delta, which is the cheap honest signal for a
    /// per-run cost comparison on iOS. Public so the live-mic Lab mode can bracket a
    /// capture with it.
    public nonisolated static func residentSizeBytes() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
        #else
        return 0
        #endif
    }
}

struct LabTranscribeError: Error { let message: String }

/// Resume a checked continuation exactly once (engines can fire complete+error).
private final class ResumeOnceBox: @unchecked Sendable {
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
