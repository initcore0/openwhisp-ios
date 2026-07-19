import SwiftUI
import CaptureKit
import MobileCore
import OpenWhispCore

/// Honest download indicator shared by Settings → Models & Storage and
/// onboarding. WhisperKit reports real 0…1 progress, so it gets a percent bar.
/// Parakeet (FluidAudio) self-stages with NO progress callback — its closure
/// jumps 0 → 1 — so a determinate bar would sit at 0% for the whole download.
/// For Parakeet (or before the first WhisperKit progress tick) we show an
/// indeterminate spinner instead of a lying 0%.
struct ModelDownloadRow: View {
    let model: ModelID
    /// Latest fraction from the provisioning callback (0…1).
    let fraction: Double

    private var showsPercent: Bool {
        !IOSModelProvisioning.isParakeet(model) && fraction > 0
    }

    var body: some View {
        if showsPercent {
            ProgressView(value: fraction) {
                Text("Downloading… \(Int(fraction * 100))%")
            }
        } else {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading…")
                    Text("This can take a few minutes on Wi-Fi. Keep the app open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

enum ModelDisplay {
    /// Human-readable name for a model id: the raw ids
    /// ("openai_whisper-large-v3-v20240930_626MB", "parakeet-unified-320ms")
    /// are developer handles, not UI copy.
    static func name(for id: ModelID) -> String {
        if IOSModelProvisioning.isParakeet(id) {
            return ParakeetCatalog.variant(for: id.rawValue).name
        }
        return WhisperKitModelCatalog.displayInfo(for: id.rawValue).label
    }
}
