import Foundation
import MobileCore
import OpenWhispCore

/// iOS conformer of `MobileCore.ModelProvisioning` (ARCHITECTURE §6.3, WP3).
///
/// Stages transcription models into the HOST app container (never the App Group —
/// the keyboard must not pay for models it can't run). Bridges the two engine
/// families' very different provisioning stories behind one seam:
///
///   - WhisperKit: real, granular download-with-progress via
///     `WhisperKitMobileBridge.downloadModel`, staged flat under
///     `WhisperKitModelCatalog.baseDir/<model>`. `staged` reflects the catalog's
///     three-`.mlmodelc` integrity check.
///   - Parakeet (FluidAudio): FluidAudio SELF-STAGES on first use with no progress
///     callback. We can't report a percentage, so `download` here triggers a
///     prefetch (loading the streaming variant downloads its repo) and reports the
///     coarse `ParakeetDownloadState` via `parakeetState(for:)` — the honest
///     three-state indicator the mac Models pane uses. `download`'s progress
///     closure gets 0 at start and 1 when the prefetch completes (no fake middle).
///
/// Model ids are the stable string handles: WhisperKit ids ("openai_whisper-…")
/// and `ParakeetCatalog` variant ids ("parakeet-unified-320ms", …). `isParakeet`
/// distinguishes them.
@MainActor
public final class IOSModelProvisioning: ModelProvisioning {

    /// Variant ids with a Parakeet prefetch currently in flight (drives the coarse
    /// "Downloading…" state, since FluidAudio gives no progress).
    private var parakeetInFlight: Set<String> = []

    /// Prefetch engines keyed by variant id, kept alive while their download runs.
    private var prefetchEngines: [String: ParakeetMobileEngine] = [:]

    public init() {}

    // MARK: - ModelProvisioning

    public nonisolated var staged: [StagedModel] {
        var out: [StagedModel] = []
        // WhisperKit staged models (flat folders under the catalog base dir).
        for model in WhisperKitModelCatalog.stagedModels() {
            let folder = WhisperKitModelCatalog.baseDir.appendingPathComponent(model, isDirectory: true)
            let size = Self.folderSize(folder)
            let stagedAt = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.creationDate] as? Date) ?? nil
            out.append(StagedModel(id: ModelID(model), sizeBytes: size, stagedAt: stagedAt ?? Date(timeIntervalSince1970: 0)))
        }
        // Parakeet installed variants (FluidAudio repo folders present on disk).
        let installed = Self.installedParakeetFolders()
        for variant in ParakeetCatalog.variants {
            guard let folder = ParakeetDownloadStatePolicy.repoFolder(forVariant: variant.id),
                  installed.contains(folder) else { continue }
            let dir = Self.fluidAudioModelsDir().appendingPathComponent(folder, isDirectory: true)
            out.append(StagedModel(
                id: ModelID(variant.id),
                sizeBytes: Self.folderSize(dir),
                stagedAt: (try? FileManager.default.attributesOfItem(atPath: dir.path)[.creationDate] as? Date).flatMap { $0 } ?? Date(timeIntervalSince1970: 0)
            ))
        }
        return out
    }

    public func download(_ model: ModelID, progress: @escaping (Double) -> Void) async throws {
        if Self.isParakeet(model) {
            try await downloadParakeet(model, progress: progress)
        } else {
            progress(0)
            try await WhisperKitMobileFileEngine.downloadModel(model.rawValue) { fraction in
                progress(fraction)
            }
            progress(1)
        }
    }

    public func delete(_ model: ModelID) throws {
        if Self.isParakeet(model) {
            guard let folder = ParakeetDownloadStatePolicy.repoFolder(forVariant: model.rawValue) else { return }
            let dir = Self.fluidAudioModelsDir().appendingPathComponent(folder, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        } else {
            let dir = WhisperKitModelCatalog.baseDir.appendingPathComponent(model.rawValue, isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// PROVISIONAL recommendation table (ARCHITECTURE §6.3: "initial guesses
    /// documented as provisional until WP3 benchmarks"). Once the benchmark matrix
    /// (peak RSS × device) lands in docs/BENCHMARKS.md, replace these with measured
    /// picks. Parakeet is the primary engine (D5), so the default is a Parakeet
    /// variant on every class; the multilingual (Nemotron) variant is heavier
    /// (~600 MB, 1.12 s latency) so it isn't the low-RAM default.
    public nonisolated func recommendedDefault(for device: DeviceClass) -> ModelID {
        switch device {
        case .low:
            // Lightest footprint that still streams with punctuation: the English
            // Unified realtime tier. (The EOU 120M is smaller but drops punctuation.)
            return ModelID(ParakeetCatalog.defaultVariantID) // parakeet-unified-320ms
        case .mid:
            return ModelID(ParakeetCatalog.defaultVariantID)
        case .high:
            // Roomy enough for the multilingual default — the product's headline.
            return ModelID("nemotron-multilingual-1120ms")
        }
    }

    // MARK: - Parakeet coarse state (no progress from FluidAudio)

    /// Coarse three-state download indicator for a Parakeet variant, via the pure
    /// upstream policy. Use this to render the Models pane badge — there is no
    /// percentage to show.
    public func parakeetState(for variantID: String) -> ParakeetDownloadState {
        ParakeetDownloadStatePolicy.state(
            forVariant: variantID,
            installedFolders: Self.installedParakeetFolders(),
            inFlightVariants: parakeetInFlight
        )
    }

    private func downloadParakeet(_ model: ModelID, progress: @escaping (Double) -> Void) async throws {
        let variant = ParakeetCatalog.normalize(model.rawValue)
        progress(0)
        parakeetInFlight.insert(variant)
        defer {
            parakeetInFlight.remove(variant)
            prefetchEngines[variant] = nil
        }
        // Loading the streaming variant downloads + stages its FluidAudio repo. We
        // keep the engine alive for the duration; there is no partial progress, so
        // the closure jumps 0 → 1.
        let engine = ParakeetMobileEngine(variantID: variant)
        prefetchEngines[variant] = engine
        await engine.prefetchAwaiting()
        // Verify the repo actually landed; if not, surface a failure rather than a
        // silent "done".
        guard parakeetState(for: variant) == .installed else {
            throw ModelProvisioningError.parakeetStageFailed(variant)
        }
        progress(1)
    }

    // MARK: - Disk helpers

    /// FluidAudio's on-disk models directory: `<appSupport>/FluidAudio/Models`.
    nonisolated static func fluidAudioModelsDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static func installedParakeetFolders() -> Set<String> {
        let dir = fluidAudioModelsDir()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names)
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    public nonisolated static func isParakeet(_ model: ModelID) -> Bool {
        ParakeetCatalog.variants.contains { $0.id == model.rawValue }
            || model.rawValue.hasPrefix("parakeet-")
            || model.rawValue.hasPrefix("nemotron-")
    }
}

public enum ModelProvisioningError: Error, LocalizedError {
    case parakeetStageFailed(String)
    public var errorDescription: String? {
        switch self {
        case .parakeetStageFailed(let v):
            return "Parakeet variant \"\(v)\" did not finish staging."
        }
    }
}
