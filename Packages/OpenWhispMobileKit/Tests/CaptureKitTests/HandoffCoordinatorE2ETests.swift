import XCTest
import MobileCore
import OpenWhispCore
@testable import CaptureKit

/// WP5 gate: the floor/hero publish path driven through the REAL file-based
/// `AppGroupHandoffStore` (a temp directory) + the REAL `DarwinHandoffNotifier`,
/// with a `FileSharedStateStore` mirroring the coarse capture state.
///
/// This is the end-to-end contract the keyboard depends on:
///   begin(.keyboardHandoff) -> engineFinal(raw) -> clean -> publish
///     ⇒ the tempdir store holds the CLEANED text (never the raw),
///     ⇒ the Darwin notifier fired,
///     ⇒ the shared capture state ends back at `.idle`.
/// It complements `CaptureCoordinatorTests` (which uses in-memory fakes) by
/// proving the ACTUAL cross-process conformers, not stand-ins.
@MainActor
final class HandoffCoordinatorE2ETests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp5-handoff-e2e-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func drain() async {
        await Task.yield(); await Task.yield(); await Task.yield()
    }

    func testKeyboardHandoffPublishesCleanedTextToRealStore() async throws {
        // REAL file-based store + REAL shared-state file in a temp directory.
        let store = try AppGroupHandoffStore(directory: dir)
        let sharedState = try FileSharedStateStore(directory: dir)
        // REAL Darwin notifier; we observe its ping via a second instance's callback
        // (Darwin notifications are process-wide, so a sibling observer receives it).
        let notifier = DarwinHandoffNotifier()
        let observer = DarwinHandoffNotifier()
        let pinged = expectation(description: "darwin ping received")
        observer.onPublished = { pinged.fulfill() }

        let engine = FakeStreamingEngine()
        let session = FakeAudioSession()
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: session,
            handoffStore: store,
            notifier: notifier,
            sharedState: sharedState,
            cleanerConfig: TestCleaner.config(),
            language: "en"
        )

        // begin(.keyboardHandoff): trigger -> startAudio -> audioReady -> startEngine.
        await coordinator.begin(trigger: .keyboardHandoff)
        await drain()
        // The coarse cross-process state is now "capturing" (the mic key mirrors it).
        XCTAssertEqual(sharedState.readCaptureState(), .capturing,
                       "begin must mark the shared state capturing")

        // Speak, then stop -> transcribing.
        engine.emitLevel(display: 0.5, vad: 0.5)
        await drain()
        await coordinator.stop()
        await drain()
        XCTAssertEqual(sharedState.readCaptureState(), .transcribing,
                       "stop must mark the shared state transcribing")

        // Engine final (RAW) -> cleaned -> published.
        let raw = "gpt is great"
        engine.emitFinal(raw)
        await drain()

        // The REAL store holds the CLEANED text, not the raw transcript.
        let published = try store.peek()
        XCTAssertNotNil(published, "a final must publish a transcript to the real store")
        XCTAssertEqual(published?.text, TestCleaner.expected(for: raw))
        XCTAssertNotEqual(published?.text, raw, "raw text must never reach the store")
        // keyboardHandoff stamps source .appSwitch.
        XCTAssertEqual(published?.source, .appSwitch)

        // The Darwin ping fired (best-effort but reliable in-process).
        await fulfillment(of: [pinged], timeout: 2.0)

        // Terminal: the coarse shared state settles back to idle so the mic key
        // stops showing "busy".
        XCTAssertEqual(sharedState.readCaptureState(), .idle,
                       "after publish the shared capture state must be idle")

        // And the coordinator's rich state is .published with the store's id.
        guard case .published(let id) = coordinator.state else {
            return XCTFail("expected .published, got \(coordinator.state)")
        }
        XCTAssertEqual(id, published?.id)
    }

    /// A cancelled keyboard-handoff capture publishes NOTHING and leaves the
    /// shared state idle — the keyboard must never insert a discarded dictation.
    func testCancelledHandoffPublishesNothing() async throws {
        let store = try AppGroupHandoffStore(directory: dir)
        let sharedState = try FileSharedStateStore(directory: dir)
        let engine = FakeStreamingEngine()
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: FakeAudioSession(),
            handoffStore: store,
            sharedState: sharedState,
            cleanerConfig: TestCleaner.config(),
            language: "en"
        )

        await coordinator.begin(trigger: .keyboardHandoff)
        await drain()
        engine.emitLevel(display: 0.5, vad: 0.5)
        await drain()
        await coordinator.cancel()
        await drain()

        XCTAssertNil(try store.peek(), "a cancelled capture must publish nothing")
        XCTAssertEqual(sharedState.readCaptureState(), .idle,
                       "a cancelled capture must leave the shared state idle")
    }
}
