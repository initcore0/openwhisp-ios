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

        // silenceStopped → transcribing, stop audio.
        effects = flow.handle(.silenceStopped)
        XCTAssertEqual(flow.state, .transcribing)
        XCTAssertEqual(effects, [.stopAudio, .updateActivity(.transcribing)])

        // engineFinal → clean + publish (inApp source).
        effects = flow.handle(.engineFinal("hello world"))
        XCTAssertEqual(effects, [
            .clean(raw: "hello world"),
            .publish(text: "hello world", source: .inApp),
        ])

        // driver reports the store write.
        let id = UUID()
        flow.didPublish(id: id)
        XCTAssertEqual(flow.state, .published(id))
    }

    func testManualStopAlsoTranscribes() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        let effects = flow.handle(.manualStop)
        XCTAssertEqual(flow.state, .transcribing)
        XCTAssertEqual(effects, [.stopAudio, .updateActivity(.transcribing)])
    }

    // MARK: Source mapping

    func testAppIntentTriggerStampsAppIntentSource() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.appIntent))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.silenceStopped)
        let effects = flow.handle(.engineFinal("hi"))
        XCTAssertEqual(effects, [.clean(raw: "hi"), .publish(text: "hi", source: .appIntent)])
    }

    func testKeyboardHandoffTriggerStampsAppSwitchSource() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.keyboardHandoff))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.manualStop)
        let effects = flow.handle(.engineFinal("hi"))
        XCTAssertEqual(effects, [.clean(raw: "hi"), .publish(text: "hi", source: .appSwitch)])
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
        XCTAssertEqual(effects, [.stopAudio, .endActivity])
    }

    func testCancelFromTranscribingDoesNotStopAudioAgain() {
        var flow = CaptureFlow()
        _ = flow.handle(.trigger(.inApp))
        _ = flow.handle(.audioReady)
        _ = flow.handle(.silenceStopped)   // already stopped audio
        let effects = flow.handle(.cancel)
        XCTAssertEqual(flow.state, .idle)
        XCTAssertEqual(effects, [.endActivity])
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
        XCTAssertEqual(effects, [.stopAudio, .abort(.sessionInterrupted)])
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
        XCTAssertEqual(effects, [.abort(.sessionInterrupted)])
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
            .engineFinal("t"), .engineError("e"), .interrupted,
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
                      .manualStop, .engineFinal("x"), .engineError("y"), .interrupted] {
            var flow = CaptureFlow()
            let effects = flow.handle(event)
            XCTAssertEqual(flow.state, .idle)
            XCTAssertEqual(effects, [], "event \(event) should be a no-op in idle")
        }
    }
}
