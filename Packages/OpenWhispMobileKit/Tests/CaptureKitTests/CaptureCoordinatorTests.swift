import XCTest
import MobileCore
import OpenWhispCore
@testable import CaptureKit

/// End-to-end tests for `CaptureCoordinator` driving the `CaptureFlow` state machine
/// with protocol fakes + an in-memory handoff store. No network / models / mic /
/// simulator — the always-green `swift test` gate.
///
/// The load-bearing assertion (ARCHITECTURE §6.2 contract): the PUBLISHED text is
/// the CLEANED text, and cancel/interruption paths never publish. The fakes' raw
/// transcript ("gpt is great") differs from its cleaned form ("GPT is great."), so
/// if raw text ever reached publish these tests fail loudly.
@MainActor
final class CaptureCoordinatorTests: XCTestCase {

    // Helpers to build a coordinator + its collaborators.
    private func makeCoordinator(
        silenceConfig: SilenceAutoStop.Config = .default
    ) -> (CaptureCoordinator, FakeStreamingEngine, FakeAudioSession, InMemoryHandoffStore, FakeNotifier) {
        let engine = FakeStreamingEngine()
        let session = FakeAudioSession()
        let store = InMemoryHandoffStore()
        let notifier = FakeNotifier()
        // Deterministic monotonic clock the test advances by emitting timestamps.
        let coordinator = CaptureCoordinator(
            engine: engine,
            session: session,
            handoffStore: store,
            notifier: notifier,
            cleanerConfig: TestCleaner.config(),
            language: "en",
            silenceConfig: silenceConfig
        )
        return (coordinator, engine, session, store, notifier)
    }

    /// Let queued `Task { @MainActor in … }` hops (engine callbacks) run.
    private func drain() async {
        await Task.yield()
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Happy path: trigger → published cleaned text

    func testFullFlowPublishesCleanedText() async throws {
        let (coordinator, engine, session, store, notifier) = makeCoordinator()

        // trigger → startAudio → (session.activate) → audioReady → startEngine
        await coordinator.begin(trigger: .appIntent)
        await drain()

        XCTAssertEqual(session.activateCount, 1, "startAudio must activate the session")
        XCTAssertEqual(engine.startCount, 1, "audioReady must start the engine")
        XCTAssertEqual(engine.lastLanguage, "en")
        // Listening now.
        guard case .listening = coordinator.state else {
            return XCTFail("expected .listening, got \(coordinator.state)")
        }

        // A live level while listening updates state (Live Activity).
        engine.emitLevel(display: 0.5, vad: 0.5)
        await drain()

        // Manual stop → stopAudio (engine.stop) → transcribing.
        await coordinator.stop()
        await drain()
        XCTAssertEqual(engine.stopCount, 1, "manualStop must stop the engine")
        XCTAssertEqual(coordinator.state, .transcribing)

        // Engine returns its RAW final; the coordinator must clean it before publish.
        let raw = "gpt is great"
        engine.emitFinal(raw)
        await drain()

        // The published transcript is the CLEANED text — never the raw.
        let published = try store.peek()
        XCTAssertNotNil(published, "a final should publish a transcript")
        let expected = TestCleaner.expected(for: raw)
        XCTAssertEqual(published?.text, expected)
        XCTAssertNotEqual(published?.text, raw, "raw text must never reach publish")
        XCTAssertEqual(published?.source, .appIntent, "source must reflect the trigger")
        XCTAssertEqual(notifier.notifyCount, 1, "publish must ping the notifier")

        // Terminal state is .published(id) with the same id as the store entry.
        guard case .published(let id) = coordinator.state else {
            return XCTFail("expected .published, got \(coordinator.state)")
        }
        XCTAssertEqual(id, published?.id)
        // Session released after publish.
        XCTAssertGreaterThanOrEqual(session.deactivateCount, 1)
    }

    // MARK: - Silence auto-stop drives the hands-free stop

    func testSilenceAutoStopTriggersTranscribeAndPublish() async throws {
        // Tight silence config so a short real-time run of samples fires it. The
        // coordinator feeds the engine's VAD level into SilenceAutoStop using a real
        // monotonic clock, so the test emits levels with real gaps: enough speech
        // samples to cross minSpeechToArm, then a silence run past silenceToStop.
        let cfg = SilenceAutoStop.Config(
            speechLevel: 0.16, silenceLevel: 0.10, silenceToStop: 0.06, minSpeechToArm: 0.04
        )
        let (coordinator, engine, _, store, _) = makeCoordinator(silenceConfig: cfg)

        await coordinator.begin(trigger: .inApp)
        await drain()

        // Speech samples with real time between them accumulate arm credit.
        for _ in 0..<5 {
            engine.emitLevel(display: 0.6, vad: 0.6)
            await drain()
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
        }
        // Silence run: quiet samples spaced past silenceToStop.
        var fired = false
        for _ in 0..<8 {
            engine.emitLevel(display: 0.02, vad: 0.02)
            await drain()
            if engine.stopCount == 1 { fired = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(fired, "silence auto-stop must eventually stop the engine")
        XCTAssertEqual(coordinator.state, .transcribing)

        engine.emitFinal("gpt is great")
        await drain()
        XCTAssertNotNil(try store.peek(), "silence-stopped capture still transcribes + publishes")
    }

    // MARK: - Cancel never publishes

    func testCancelNeverPublishes() async throws {
        let (coordinator, engine, _, store, notifier) = makeCoordinator()

        await coordinator.begin(trigger: .keyboardHandoff)
        await drain()
        engine.emitLevel(display: 0.5, vad: 0.5)
        await drain()

        // Cancel mid-listen.
        await coordinator.cancel()
        await drain()

        XCTAssertEqual(engine.cancelCount, 1, "cancel must cancel the engine")
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(try store.peek(), "cancel must publish nothing")
        XCTAssertEqual(notifier.notifyCount, 0)

        // Even a late final after cancel must not publish (flow is back to idle).
        engine.emitFinal("gpt is great")
        await drain()
        XCTAssertNil(try store.peek(), "a final after cancel must not publish")
    }

    // MARK: - Cancel during transcribing stops the in-flight engine (Finding 2)

    func testCancelDuringTranscribingStopsEngine() async throws {
        let (coordinator, engine, _, store, notifier) = makeCoordinator()

        // Drive to .transcribing via a manual stop (engine still running its decode).
        await coordinator.begin(trigger: .inApp)
        await drain()
        await coordinator.stop()
        await drain()
        XCTAssertEqual(coordinator.state, .transcribing)
        // Manual stop stopped the engine with cancel:false (let it finish).
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.cancelCount, 0)

        // Cancel the in-flight decode. Before Finding 2 this emitted no engine-stop
        // effect, so the decode ran to completion wastefully. Now it must cancel it.
        await coordinator.cancel()
        await drain()

        XCTAssertEqual(engine.cancelCount, 1, "cancel during transcribing must stop the engine with cancel:true")
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(try store.peek(), "a cancelled decode must publish nothing")
        XCTAssertEqual(notifier.notifyCount, 0)

        // Even a late final (if the engine ignored the cancel) must not publish.
        engine.emitFinal("gpt is great")
        await drain()
        XCTAssertNil(try store.peek(), "a final after cancel must not publish")
    }

    // MARK: - Interruption mid-capture aborts + stops the engine (Finding 1)

    func testSessionInterruptionWhileListeningAbortsAndStopsEngine() async throws {
        let (coordinator, engine, session, store, notifier) = makeCoordinator()

        await coordinator.begin(trigger: .inApp)
        await drain()
        engine.emitLevel(display: 0.5, vad: 0.5)
        await drain()
        guard case .listening = coordinator.state else {
            return XCTFail("expected .listening, got \(coordinator.state)")
        }

        // The OS interrupts the live session (phone call / Siri / headset unplug).
        session.fireInterruption()
        await drain()

        XCTAssertEqual(engine.cancelCount, 1, "interruption while listening must cancel the engine")
        XCTAssertEqual(coordinator.state, .failed(.sessionInterrupted))
        XCTAssertNil(try store.peek(), "an interrupted capture publishes nothing")
        XCTAssertEqual(notifier.notifyCount, 0)
    }

    func testSessionInterruptionWhileTranscribingAbortsAndStopsEngine() async throws {
        let (coordinator, engine, session, store, _) = makeCoordinator()

        await coordinator.begin(trigger: .inApp)
        await drain()
        await coordinator.stop()   // → .transcribing, engine finishing its decode
        await drain()
        XCTAssertEqual(coordinator.state, .transcribing)

        // Interruption arrives while the engine is still decoding.
        session.fireInterruption()
        await drain()

        XCTAssertEqual(engine.cancelCount, 1, "interruption while transcribing must cancel the engine")
        XCTAssertEqual(coordinator.state, .failed(.sessionInterrupted))
        XCTAssertNil(try store.peek(), "an interrupted decode publishes nothing")
    }

    // MARK: - Interruption never publishes

    func testInterruptionAbortsAndNeverPublishes() async throws {
        let (coordinator, engine, session, store, _) = makeCoordinator()
        // Make the SESSION activation fail → the coordinator maps it to interrupted.
        session.activationError = FakeError(message: "session busy")

        await coordinator.begin(trigger: .appIntent)
        await drain()

        // startAudio failed → interrupted → failed state, engine never started.
        XCTAssertEqual(engine.startCount, 0, "engine must not start if the session failed")
        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
        XCTAssertEqual(failure, .sessionInterrupted)
        XCTAssertNil(try store.peek(), "an interrupted capture publishes nothing")
    }

    // MARK: - Engine error never publishes

    func testEngineErrorWhileListeningNeverPublishes() async throws {
        let (coordinator, engine, _, store, _) = makeCoordinator()

        await coordinator.begin(trigger: .inApp)
        await drain()
        engine.emitLevel(display: 0.5, vad: 0.5)
        await drain()

        engine.emitError("engine blew up")
        await drain()

        guard case .failed(let failure) = coordinator.state else {
            return XCTFail("expected .failed, got \(coordinator.state)")
        }
        XCTAssertEqual(failure, .engineError("engine blew up"))
        XCTAssertNil(try store.peek(), "an engine error publishes nothing")
    }

    // MARK: - An ignorable/empty transcript publishes nothing

    func testEmptyCleanedTranscriptDoesNotPublish() async throws {
        let (coordinator, engine, _, store, notifier) = makeCoordinator()

        await coordinator.begin(trigger: .inApp)
        await drain()
        await coordinator.stop()
        await drain()

        // A transcript that cleans to empty (a non-speech marker) must NOT publish.
        engine.emitFinal("[BLANK_AUDIO]")
        await drain()

        XCTAssertNil(try store.peek(), "an ignorable transcript publishes nothing")
        XCTAssertEqual(notifier.notifyCount, 0)
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - Partials bypass the publish contract

    func testPartialsForwardedButNotPublished() async throws {
        let (coordinator, engine, _, store, _) = makeCoordinator()
        var partials: [String] = []
        coordinator.onPartial = { partials.append($0) }

        await coordinator.begin(trigger: .inApp)
        await drain()
        engine.emitPartial("gpt")
        engine.emitPartial("gpt is")
        await drain()

        XCTAssertEqual(partials, ["gpt", "gpt is"], "partials are forwarded verbatim")
        XCTAssertNil(try store.peek(), "partials must never publish")
    }
    // MARK: - Raw-final hook (history revert data)

    func testOnRawFinalFiresWithRawTextBeforeCleaning() async throws {
        let (coordinator, engine, _, store, _) = makeCoordinator()
        var raws: [String] = []
        coordinator.onRawFinal = { raws.append($0) }

        await coordinator.begin(trigger: .inApp)
        await drain()
        await coordinator.stop()
        await drain()

        let raw = "gpt is great"
        engine.emitFinal(raw)
        await drain()

        XCTAssertEqual(raws, [raw], "onRawFinal must deliver the raw engine text exactly once")
        // And the published transcript is still the cleaned text, not the raw.
        let published = try store.peek()
        XCTAssertEqual(published?.text, TestCleaner.expected(for: raw))
        XCTAssertNotEqual(published?.text, raw)
    }

}
