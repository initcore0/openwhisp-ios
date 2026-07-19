import Foundation
import MobileCore
import OpenWhispCore

/// Which engine + model a capture surface wants. A value type so it can key the
/// process-wide cache below.
public enum EngineSelection: Hashable, Sendable {
    case parakeet(variantID: String)
    case whisperKit(model: String)
}

/// Process-wide cache of streaming engines, keyed by `EngineSelection`.
///
/// Every capture surface used to construct a FRESH engine per capture
/// (`ParakeetMobileEngine(variantID:)` in the composer, sheet, and intent
/// controller), which threw away the engine's internal session cache — so every
/// dictation re-loaded the CoreML models from disk (seconds of "Preparing…" on
/// each start). The engines are built for reuse (their stream sessions `reset()`
/// per capture and their loads join in-flight work), so one instance per model
/// is the correct lifetime: first start pays the load, every later start is warm.
///
/// `warm(_:)` pre-loads an ALREADY-STAGED model off the critical path (app
/// launch / after a download). It must never trigger a download — FluidAudio
/// self-stages on load, so warming an uninstalled Parakeet variant would start
/// a silent multi-hundred-MB fetch. The staged check gates that.
@MainActor
public final class EngineCache {

    public static let shared = EngineCache()

    private var engines: [EngineSelection: StreamingTranscriptionEngine] = [:]
    private let provisioning = IOSModelProvisioning()

    private init() {}

    /// The cached engine for this selection, created on first request.
    public func engine(for selection: EngineSelection) -> StreamingTranscriptionEngine {
        if let cached = engines[selection] { return cached }
        let engine: StreamingTranscriptionEngine
        switch selection {
        case .parakeet(let variantID):
            engine = ParakeetMobileEngine(variantID: variantID)
        case .whisperKit(let model):
            engine = WhisperKitMobileEngine(modelName: model)
        }
        engines[selection] = engine
        return engine
    }

    /// Whether the selected model is staged on disk. Surfaces the "first
    /// dictation must download the model" state so the UI can be honest about
    /// it instead of showing a bare "Preparing…".
    public func isModelStaged(_ selection: EngineSelection) -> Bool {
        switch selection {
        case .parakeet(let variantID):
            return provisioning.parakeetState(for: variantID) == .installed
        case .whisperKit(let model):
            return provisioning.staged.contains { $0.id.rawValue == model }
        }
    }

    /// Pre-load the selected model into memory IF it is already staged, so the
    /// first mic tap starts listening near-instantly. No-op (and no download)
    /// when the model isn't on disk yet.
    public func warm(_ selection: EngineSelection) {
        guard isModelStaged(selection) else { return }
        let engine = engine(for: selection)
        if let parakeet = engine as? ParakeetMobileEngine {
            Task { await parakeet.prefetchAwaiting() }
        }
        // WhisperKit loads on first start; its staged load is fast enough that a
        // dedicated warm path hasn't been needed. Extend here if that changes.
    }

    /// Drop cached engines (e.g. after a model was deleted in Models & Storage,
    /// or a variant change should release the old model's memory).
    public func invalidate() {
        engines.removeAll()
    }
}
