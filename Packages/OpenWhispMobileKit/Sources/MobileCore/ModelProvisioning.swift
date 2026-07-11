import Foundation

// MARK: - Model provisioning (ARCHITECTURE §6.3)
//
// Declared in MobileCore so the seam is available to callers; the concrete
// downloader/stager lives in CaptureKit (WP3) and reuses the upstream
// `WhisperKitModelCatalog` for identity/staging checks. Models stage into the
// HOST app container, never the App Group — the keyboard must not pay for models
// it can't run.

/// Opaque model identifier (e.g. "whisper-tiny", "parakeet-unified-320ms").
/// The rich catalog identity is upstream; this is the stable string handle the
/// mobile UI passes around.
public struct ModelID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// A device RAM class, used to pick a sane default model.
public enum DeviceClass: String, Codable, Equatable, Sendable {
    case low      // ~3–4 GB RAM (iPhone SE, older)
    case mid      // ~6 GB
    case high     // 8 GB+
}

/// A model that has been downloaded and staged locally.
public struct StagedModel: Codable, Equatable, Sendable {
    public let id: ModelID
    public let sizeBytes: Int64
    public let stagedAt: Date

    public init(id: ModelID, sizeBytes: Int64, stagedAt: Date) {
        self.id = id
        self.sizeBytes = sizeBytes
        self.stagedAt = stagedAt
    }
}

/// Downloads + stages transcription models into the host app container.
///
/// Download is the ONLY non-LAN network call in the entire product: it is
/// user-initiated, shown with progress, and listed in the privacy notes.
public protocol ModelProvisioning: AnyObject {
    var staged: [StagedModel] { get }
    func download(_ model: ModelID, progress: @escaping (Double) -> Void) async throws
    func delete(_ model: ModelID) throws
    /// tiny/base/small by available RAM.
    func recommendedDefault(for device: DeviceClass) -> ModelID
}
