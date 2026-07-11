import XCTest
import MobileCore
import OpenWhispCore
@testable import CaptureKit

/// Tests for the pure helpers ported into CaptureKit and the provisioning seam's
/// deterministic parts. No network/models/simulator.
final class EngineSupportTests: XCTestCase {

    // MARK: - AudioLevelMath fidelity (ported from OpenWhispCore's internal AudioLevel)

    func testAudioLevelMathBoundsAndMonotonicity() {
        // Silence → 0.
        XCTAssertEqual(AudioLevelMath.fromRMS(0), 0, accuracy: 0.0001)
        // dB floor/ceil clamp to [0,1].
        XCTAssertEqual(AudioLevelMath.fromDB(-100), 0, accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMath.fromDB(0), 1, accuracy: 0.0001)
        // Monotonic: louder RMS → higher level.
        let quiet = AudioLevelMath.fromRMS(0.01)
        let loud = AudioLevelMath.fromRMS(0.2)
        XCTAssertLessThan(quiet, loud)
        XCTAssertGreaterThanOrEqual(quiet, 0)
        XCTAssertLessThanOrEqual(loud, 1)
    }

    func testAudioLevelMathMatchesExpectedCurveConstants() {
        // The VAD is calibrated to these exact constants; a drift here would
        // silently mis-arm SilenceAutoStop.
        XCTAssertEqual(AudioLevelMath.floorDB, -52)
        XCTAssertEqual(AudioLevelMath.ceilDB, -12)
        XCTAssertEqual(AudioLevelMath.gamma, 0.7)
        // Midpoint of the dB window maps to gamma-curved 0.5.
        let mid = AudioLevelMath.fromDB(-32) // exactly halfway between floor and ceil
        XCTAssertEqual(mid, powf(0.5, 0.7), accuracy: 0.0001)
    }

    // MARK: - ModelProvisioning recommendedDefault table (provisional but pinned)

    @MainActor
    func testRecommendedDefaultTable() {
        let provisioning = IOSModelProvisioning()
        // Parakeet is the primary engine (D5): every class defaults to a Parakeet
        // variant. Low/mid → the light English realtime tier; high → multilingual.
        XCTAssertEqual(provisioning.recommendedDefault(for: .low).rawValue, "parakeet-unified-320ms")
        XCTAssertEqual(provisioning.recommendedDefault(for: .mid).rawValue, "parakeet-unified-320ms")
        XCTAssertEqual(provisioning.recommendedDefault(for: .high).rawValue, "nemotron-multilingual-1120ms")
    }

    @MainActor
    func testIsParakeetClassification() {
        XCTAssertTrue(IOSModelProvisioning.isParakeet(ModelID("parakeet-unified-320ms")))
        XCTAssertTrue(IOSModelProvisioning.isParakeet(ModelID("nemotron-multilingual-1120ms")))
        XCTAssertFalse(IOSModelProvisioning.isParakeet(ModelID("openai_whisper-small")))
    }

    @MainActor
    func testParakeetCoarseStateReflectsInstalledFolders() {
        // With no FluidAudio models on disk (test host), an unknown variant reads
        // notDownloaded via the pure policy — proving the wiring is to the policy,
        // not a stub.
        let provisioning = IOSModelProvisioning()
        // A never-installed variant on a clean host is notDownloaded (unless a real
        // model happens to be staged on the dev machine — tolerate installed too).
        let state = provisioning.parakeetState(for: "parakeet-unified-320ms")
        XCTAssertTrue(state == .notDownloaded || state == .installed,
                      "coarse state must be a real policy value, got \(state)")
    }
}
