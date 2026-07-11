import Foundation

// MARK: - Engine Lab run records (WP3, product Goal #1 instrument)
//
// The Engine Lab runs a fixture (or live mic) through an engine and records the
// outcome: transcript, WER vs. reference, latency, realtime factor, peak-RSS delta.
// Those records are the EVIDENCE that OpenWhisp beats Apple's baseline, so they are
// persisted (last N) as JSON for later export — same discipline as the Mac's
// benchmark logs.
//
// These are pure value types + a pure "keep last N" reducer, so the persistence
// policy is unit-tested on the `swift test` gate. The concrete on-disk store (a
// thin JSON file wrapper) lives in the host app; this file owns the SHAPE and the
// bounding rule.

/// Which engine family produced a run (for grouping + the "vs Apple" verdict).
public enum LabEngineKind: String, Codable, Equatable, Sendable {
    case parakeet
    case whisperKit
    /// Apple's on-device `SFSpeechRecognizer` — BENCHMARK BASELINE ONLY, never a
    /// production path (ARCHITECTURE §7 / D5). Present here only so the Lab can
    /// score against it.
    case appleBaseline
}

/// The performance metrics captured for one transcription.
public struct LabMetrics: Codable, Equatable, Sendable {
    /// Wall-clock seconds from "start transcribe" to "final text delivered".
    public let latencySeconds: Double
    /// Audio duration in seconds (fixture length, or measured live-capture length).
    public let audioSeconds: Double
    /// Peak resident-set-size DELTA during the run, in bytes (0 if unmeasured).
    /// A delta (not absolute) so it reflects the run's memory cost, not the app's
    /// baseline footprint. Best-effort on iOS via `task_info`.
    public let peakRSSDeltaBytes: Int64

    public init(latencySeconds: Double, audioSeconds: Double, peakRSSDeltaBytes: Int64) {
        self.latencySeconds = latencySeconds
        self.audioSeconds = audioSeconds
        self.peakRSSDeltaBytes = peakRSSDeltaBytes
    }

    /// Realtime factor = processing time / audio duration. < 1.0 means faster than
    /// realtime (the bar for live dictation). nil when audio duration is unknown/0.
    public var realtimeFactor: Double? {
        guard audioSeconds > 0 else { return nil }
        return latencySeconds / audioSeconds
    }

    public var realtimeFactorString: String {
        guard let rtf = realtimeFactor else { return "—" }
        return String(format: "%.2f×", rtf)
    }

    public var peakRSSDeltaString: String {
        guard peakRSSDeltaBytes != 0 else { return "—" }
        let mb = Double(peakRSSDeltaBytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }
}

/// One recorded Engine Lab run.
public struct LabRun: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let date: Date
    /// The engine's display name (variant/model label), e.g. "Parakeet Multilingual".
    public let engineName: String
    public let engineKind: LabEngineKind
    /// The engine's model/variant id, e.g. "nemotron-multilingual-1120ms".
    public let modelID: String
    /// The fixture name ("plain_speech") or "" for a live-mic run.
    public let fixtureName: String
    /// True when this run was live-mic rather than a fixture.
    public let isLive: Bool
    /// The language hint used ("auto", "en", "ru", …).
    public let language: String
    /// The reference transcript (fixture `.txt`), or "" for live/unknown.
    public let reference: String
    /// The engine's produced transcript.
    public let hypothesis: String
    /// WER as a fraction (0…). nil when there was no reference to score against.
    public let wer: Double?
    public let metrics: LabMetrics
    /// A failure message when the run errored (transcript then empty).
    public let error: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        engineName: String,
        engineKind: LabEngineKind,
        modelID: String,
        fixtureName: String,
        isLive: Bool,
        language: String,
        reference: String,
        hypothesis: String,
        wer: Double?,
        metrics: LabMetrics,
        error: String? = nil
    ) {
        self.id = id
        self.date = date
        self.engineName = engineName
        self.engineKind = engineKind
        self.modelID = modelID
        self.fixtureName = fixtureName
        self.isLive = isLive
        self.language = language
        self.reference = reference
        self.hypothesis = hypothesis
        self.wer = wer
        self.metrics = metrics
        self.error = error
    }

    public var werPercentString: String {
        guard let wer else { return "—" }
        return String(format: "%.1f%%", wer * 100)
    }
}

/// Pure "keep the last N runs" reducer + the JSON codec, so the retention policy is
/// tested without any filesystem. The host app's `LabRunStore` calls these around a
/// single JSON file read/write.
public enum LabRunLog {
    /// Hard cap on retained lab runs (newest kept). Bounded so the JSON can't grow
    /// without limit, exactly like `TranscriptionHistoryStore.maxEntries`.
    public static let maxRuns = 100

    /// Prepend `run` to `existing` (newest-first) and trim to `maxRuns`.
    public static func appending(_ run: LabRun, to existing: [LabRun], limit: Int = maxRuns) -> [LabRun] {
        var out = existing
        out.insert(run, at: 0)
        if out.count > limit {
            out.removeLast(out.count - limit)
        }
        return out
    }

    /// Encode runs to pretty JSON (stable key order, ISO-8601 dates) for export.
    public static func encode(_ runs: [LabRun]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(runs)
    }

    public static func decode(_ data: Data) throws -> [LabRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LabRun].self, from: data)
    }
}
