import Foundation

// MARK: - AudioLevel math (ported from OpenWhispCore's internal `AudioLevel`)
//
// Upstream `AudioLevel` lives in OpenWhispCore but is `internal` (mac-only), so it
// is NOT part of the public iOS-consumable surface. WP0 promoted the protocol seams
// and the Parakeet/cleaner types to `public`, but not this loudness mapper. Rather
// than block the engine layer on another upstream visibility bump, we port the
// (small, pure, Foundation-only) curve here VERBATIM so every iOS capture path maps
// loudness the SAME way the mac app does — the fixed-threshold `SilenceAutoStop`
// gates are calibrated to exactly this `[0,1]` scale (‑52 dB floor → ‑12 dB ceil,
// gamma 0.7), so any drift here would silently mis-arm auto-stop.
//
// If upstream later makes `AudioLevel` public, delete this file and switch the call
// sites to the upstream type (they use the same names).
enum AudioLevelMath {
    /// dBFS window mapped to 0…1. Quiet room ~ -55 dB; normal speech peaks ~ -15 dB.
    static let floorDB: Float = -52
    static let ceilDB: Float = -12
    /// <1 brightens (lifts quiet speech); 0.7 gives a lively-but-not-twitchy curve.
    static let gamma: Float = 0.7

    /// Map a linear RMS amplitude (0…1, e.g. `sqrt(mean(sample^2))`) to a
    /// normalized indicator level (0…1). This is the ABSOLUTE curve the VAD needs.
    static func fromRMS(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return fromDB(db)
    }

    /// Map a dBFS value to a normalized level.
    static func fromDB(_ db: Float) -> Float {
        let clamped = min(max(db, floorDB), ceilDB)
        let t = (clamped - floorDB) / (ceilDB - floorDB)   // 0…1 linear in dB
        return powf(max(0, min(1, t)), gamma)
    }

    /// Compute the linear RMS of a raw float sample buffer (interleaved or planar
    /// handled by the caller; this takes one contiguous channel's worth or a
    /// pre-summed buffer). Foundation-only so it is unit-testable without AVFoundation.
    static func rms(of samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let s = samples[i]
            sum += s * s
        }
        return (sum / Float(count)).squareRoot()
    }
}
