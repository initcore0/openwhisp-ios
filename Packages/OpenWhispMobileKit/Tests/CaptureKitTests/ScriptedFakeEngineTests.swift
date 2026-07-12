import XCTest
import MobileCore
import OpenWhispCore
@testable import CaptureKit

/// The UI-test scripted-fake engine is DEBUG-only and gated on a launch argument.
/// These tests pin that contract: the argument toggles it under `swift test`
/// (which builds DEBUG), the fake produces its fixed final through the real
/// coordinator, and — asserted structurally — the Release path returns false.
@MainActor
final class ScriptedFakeEngineTests: XCTestCase {

    func testRequestedOnlyWithLaunchArgument() {
        XCTAssertFalse(scriptedFakeEngineRequested(arguments: ["OpenWhisp"]))
        XCTAssertTrue(scriptedFakeEngineRequested(arguments: ["OpenWhisp", "-openwhisp-uitest-fake-engine"]))
    }

    /// In a RELEASE compile the gate is hard-wired false. We cannot compile a
    /// Release binary inside `swift test`, but we CAN assert the source guarantees
    /// it: the `#else` branch returns false unconditionally. This test documents
    /// the invariant and fails loudly if the DEBUG build's behavior regresses.
    func testDebugBuildHonorsArgument() {
        #if DEBUG
        XCTAssertTrue(scriptedFakeEngineRequested(arguments: ["-openwhisp-uitest-fake-engine"]),
                      "DEBUG build must honor the fake-engine argument")
        #else
        XCTAssertFalse(scriptedFakeEngineRequested(arguments: ["-openwhisp-uitest-fake-engine"]),
                       "RELEASE build must never activate the fake engine")
        #endif
    }

    #if DEBUG
    /// The scripted fake drives the coordinator to a published, cleaned transcript
    /// with no mic/model, ending via the coordinator's REAL `SilenceAutoStop` — the
    /// same hands-free path the floor-flow XCUITest exercises.
    func testScriptedFakeDrivesCoordinatorToPublish() async throws {
        let store = InMemoryHandoffStore()
        // Fast silence config so the test doesn't wait 1.5s of real silence.
        let silence = SilenceAutoStop.Config(
            speechLevel: 0.16, silenceLevel: 0.10,
            silenceToStop: 0.2, minSpeechToArm: 0.1
        )
        let engine = ScriptedFakeEngine(tick: 0.03, speechTicks: 6, silenceTicks: 20)
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: FakeAudioSession(),
            handoffStore: store,
            cleanerConfig: TestCleaner.config(),
            language: "en",
            silenceConfig: silence
        )
        await coordinator.begin(trigger: .keyboardHandoff)

        // Poll for the publish (the scripted level curve trips SilenceAutoStop in
        // real time). Bounded so a genuine regression fails instead of hanging.
        var published: PendingTranscript?
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 30_000_000)
            await Task.yield()
            if let p = try store.peek() { published = p; break }
        }

        XCTAssertNotNil(published, "scripted fake must publish a transcript via SilenceAutoStop")
        XCTAssertEqual(published?.text,
                       TranscriptCleaner(config: TestCleaner.config())
                           .clean(ScriptedFakeEngine.fakeFinalText, isFinalTranscript: true))
    }
    #endif
}
