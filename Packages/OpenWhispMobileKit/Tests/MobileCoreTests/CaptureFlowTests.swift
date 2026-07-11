import XCTest
@testable import MobileCore

final class CaptureFlowTests: XCTestCase {

    // MARK: Happy path

    func testHappyPathInApp() {
        var flow = CaptureFlow()
        XCTAssertEqual(flow.state, .idle)

        // Trigger → preparing, start audio.
        var effects = flow.handle(.trigger(.inApp))
        XCTAssertEqual(flow.state, .preparing)
        XCTAssertEqual(effects, [.startAudio, .updateActivity(.preparing)])

        // audioReady → listening, start engine.
        effects = flow.handle(.audioReady)
        XCTAssertEqual(flow.state, .listening(level: 0))
        XCTAssertEqual(effects, [.startEngine(language: "en"), .updateActivity(.listening(level: 0))])

        // level updates keep us listening.
        effects = flow.handle(.level(0.42))
        XCTAssertEqual(flow.state, .listening(level: 0.42))
        XCTAssertEqual(effects, [.updateActivity(.listening(level: 0.42))])

        // silenceStopped → transcribing, stop audio, stop engine (let it finish).
        effects = flow.handle(.silenceStopped)
        XCTAssertEqual(flow.state, .transcribing)
        XCTAssertEqual(effects, [.stopAudio, .stopEngine(cancel: false), .updateActivity(.transcribing)])

        // engineFinal → clean ONLY (raw text can never reach publish).
        effects = flow.handle(.engineFinal("hello world"))
        XCTAssertEqual(effects, [.clean(raw: "hello world")])

        // cleaned → publish carries the cleaned text (inApp source).
        effects = flow.handle(.cleaned(text: "Hello world."))
        XCTAssertEqual(effects, [.publish(text: "Hello world.", source: .inApp)])

        // driver reports the store write; activity teardown is in the contract.
        let id = UUID()
        effects = flow.didPublish(id: id)
        XCTAssertEqual(flow.state, .published(id))
        XCTAssertEqual(effects, [.updateActivity(.published(id)), .endActivity])
    }

    /// Regression guard for the reviewed wiring hazard: a driver that executes
    /// the effect list literally must be unable to publish uncleaned text.
    func testRawEngineTextCanNeverReachPublish() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.silenceStopped)

        let finalEffects = flow.handle(.engineFinal("raw uncleaned text"))
        for effect in finalEffects {
            if case .publish = effect {
                XCTFail("engineFinal must not emit .publish — got \(effect)")
            }
        }

        let publishEffects = flow.handle(.cleaned(text: "Raw, cleaned text."))
        XCTAssertEqual(publishEffects, [.publish(text: "Raw, cleaned text.", source: .inApp)])
    }

    func testManualStopAlsoTranscribes() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        let effects = flow.handle(.manualStop)
        XCTAssertEqual(flow.state, .transcribing)
        XCTAssertEqual(effects, [.stopAudio, .stopEngine(cancel: false), .updateActivity(.transcribing)])
    }

    // MARK: Source mapping

    func testAppIntentTriggerStampsAppIntentSource() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.appIntent))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.silenceStopped)
        _ = flow.handle(.engineFinal("hi"))
        let effects = flow.handle(.cleaned(text: "Hi."))
        XCTAssertEqual(effects, [.publish(text: "Hi.", source: .appIntent)])
    }

    func testKeyboardHandoffTriggerStampsAppSwitchSource() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.keyboardHandoff))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.manualStop)
        _ = flow.handle(.engineFinal("hi"))
        let effects = flow.handle(.cleaned(text: "Hi."))
        XCTAssertEqual(effects, [.publish(text: "Hi.", source: .appSwitch)])
    }

    // MARK: Cancel paths

    func testCancelFromPreparing() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        let effects = flow.handle(.cancel)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertEqual(effects, [.stopAudio, .endActivity])
    }

    func testCancelFromListening() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        let effects = flow.handle(.cancel)
        XCTAssertEqual(flow.state, .idle)
        // Abort while listening cancels the engine's decode (cancel: true).
        XCTAssertEqual(effects, [.stopAudio, .stopEngine(cancel: true), .endActivity])
    }

    func testCancelFromTranscribingStopsEngineButNotAudioAgain() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.silenceStopped)   // already stopped audio
        let effects = flow.handle(.cancel)
        XCTAssertEqual(flow.state, .idle)
        // Audio is already stopped; cancel still stops the in-flight decode so it
        // does not complete wastefully (Finding 2).
        XCTAssertEqual(effects, [.stopEngine(cancel: true), .endActivity])
    }

    func testCancelFromIdleIsNoOp() {
        var flow = CaptureFlow()
        let effects = flow.handle(.cancel)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertEqual(effects, [])
    }

    func testCancelFromPublishedClearsActivity() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.manualStop)
        _ = flow.handle(.engineFinal("x"))
        flow.didPublish(id: UUID())
        let effects = flow.handle(.cancel)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertEqual(effects, [.endActivity])
    }

    // MARK: Error paths

    func testEngineErrorWhileListeningAborts() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        let effects = flow.handle(.engineError("boom"))
        XCTAssertEqual(flow.state, .failed(.engineError("boom")))
        XCTAssertEqual(effects, [.stopAudio, .abort(.engineError("boom"))])
    }

    func testEngineErrorWhileTranscribingAborts() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.silenceStopped)
        let effects = flow.handle(.engineError("boom"))
        XCTAssertEqual(flow.state, .failed(.engineError("boom")))
        XCTAssertEqual(effects, [.abort(.engineError("boom"))])
    }

    func testEngineErrorWhilePreparingAborts() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        let effects = flow.handle(.engineError("cold"))
        XCTAssertEqual(flow.state, .failed(.engineError("cold")))
        XCTAssertEqual(effects, [.stopAudio, .abort(.engineError("cold"))])
    }

    // MARK: Interruption paths

    func testInterruptedWhileListeningAborts() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        let effects = flow.handle(.interrupted)
        XCTAssertEqual(flow.state, .failed(.sessionInterrupted))
        // Interruption while listening: stop audio AND cancel the engine (Finding 1).
        XCTAssertEqual(effects, [.stopAudio, .stopEngine(cancel: true), .abort(.sessionInterrupted)])
    }

    func testInterruptedWhilePreparingAborts() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        let effects = flow.handle(.interrupted)
        XCTAssertEqual(flow.state, .failed(.sessionInterrupted))
        XCTAssertEqual(effects, [.stopAudio, .abort(.sessionInterrupted)])
    }

    func testInterruptedWhileTranscribingAbortsWithoutStopAudio() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.silenceStopped)
        let effects = flow.handle(.interrupted)
        XCTAssertEqual(flow.state, .failed(.sessionInterrupted))
        // Audio already stopped; interruption cancels the finishing engine (Finding 1/2).
        XCTAssertEqual(effects, [.stopEngine(cancel: true), .abort(.sessionInterrupted)])
    }

    // MARK: Restart from terminal states

    func testTriggerFromPublishedRestarts() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.manualStop)
        _ = flow.handle(.engineFinal("x"))
        flow.didPublish(id: UUID())

        let effects = flow.handle(.trigger(.appIntent))
        XCTAssertEqual(flow.state, .preparing)
        XCTAssertEqual(effects, [.startAudio, .updateActivity(.preparing)])
    }

    func testTriggerFromFailedRestarts() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.interrupted)      // → failed
        let effects = flow.handle(.trigger(.inApp))
        XCTAssertEqual(flow.state, .preparing)
        XCTAssertEqual(effects, [.startAudio, .updateActivity(.preparing)])
    }

    // MARK: Totality — no (state,event) pair crashes

    func testEveryStateEventPairIsHandledWithoutCrash() {
        let states: [CaptureState] = [
            .idle, .preparing, .listening(level: 0.1), .transcribing,
            .published(UUID()), .failed(.micDenied),
        ]
        let events: [CaptureFlow.Event] = [
            .trigger(.inApp), .trigger(.appIntent), .trigger(.keyboardHandoff),
            .audioReady, .level(0.5), .silenceStopped, .manualStop, .cancel,
            .engineFinal("t"), .cleaned(text: "c"), .engineError("e"), .interrupted,
        ]
        for state in states {
            for event in events {
                var flow = CaptureFlow(state: state)
                // Must not trap; result is intentionally unused.
                _ = flow.handle(event)
            }
        }
    }

    // MARK: Stray events in idle are ignored

    func testStrayEventsInIdleAreIgnored() {
        for event in [CaptureFlow.Event.audioReady, .level(0.3), .silenceStopped,
                      .manualStop, .engineFinal("x"), .cleaned(text: "c"),
                      .engineError("y"), .interrupted] {
            var flow = CaptureFlow()
            let effects = flow.handle(event)
            XCTAssertEqual(flow.state, .idle)
            XCTAssertEqual(effects, [], "event \(event) should be a no-op in idle")
        }
    }
}
