import XCTest
@testable import MobileCore

/// The pure live-partial throttle + sequencer (WP10b, D12/R10b). Exhaustively covers
/// the write/drop decision: throttle window, monotonic seq, duplicate suppression,
/// never-throttled finals, and per-capture reset.
final class LivePartialPublisherTests: XCTestCase {

    private let d0 = Date(timeIntervalSince1970: 3_000_000)

    func testNoCaptureInProgressYieldsNil() {
        var pub = LivePartialPublisher()
        XCTAssertNil(pub.offer("hi", now: 0, at: d0))
        XCTAssertNil(pub.final("hi", at: d0))
    }

    func testFirstInterimIsNeverThrottled() {
        var pub = LivePartialPublisher()
        let id = pub.begin()
        let p = pub.offer("hello", now: 100, at: d0)
        XCTAssertEqual(p?.captureID, id)
        XCTAssertEqual(p?.seq, 1)
        XCTAssertEqual(p?.text, "hello")
        XCTAssertEqual(p?.isFinal, false)
    }

    func testWithinWindowIsDropped() {
        var pub = LivePartialPublisher()
        _ = pub.begin()
        XCTAssertNotNil(pub.offer("a", now: 100, at: d0))
        // < 125 ms later → throttled.
        XCTAssertNil(pub.offer("ab", now: 100.05, at: d0))
    }

    func testAtOrBeyondWindowIsWritten() {
        var pub = LivePartialPublisher()
        _ = pub.begin()
        XCTAssertNotNil(pub.offer("a", now: 100, at: d0))
        let p = pub.offer("abc", now: 100.125, at: d0)
        XCTAssertEqual(p?.seq, 2)
        XCTAssertEqual(p?.text, "abc")
    }

    func testSeqIsMonotonicAcrossAcceptedWrites() {
        var pub = LivePartialPublisher()
        _ = pub.begin()
        XCTAssertEqual(pub.offer("a", now: 0, at: d0)?.seq, 1)
        XCTAssertEqual(pub.offer("ab", now: 1, at: d0)?.seq, 2)
        XCTAssertEqual(pub.offer("abc", now: 2, at: d0)?.seq, 3)
    }

    func testDuplicateTextIsSuppressed() {
        var pub = LivePartialPublisher()
        _ = pub.begin()
        XCTAssertNotNil(pub.offer("same", now: 0, at: d0))
        // Identical text past the window is still a no-op write.
        XCTAssertNil(pub.offer("same", now: 10, at: d0))
    }

    func testFinalIsNeverThrottled() {
        var pub = LivePartialPublisher()
        _ = pub.begin()
        XCTAssertNotNil(pub.offer("raw text", now: 0, at: d0))
        // A final immediately after an accepted interim is NOT throttled.
        let f = pub.final("Clean text.", now: 0.001)
        XCTAssertEqual(f?.isFinal, true)
        XCTAssertEqual(f?.text, "Clean text.")
        XCTAssertEqual(f?.seq, 2)
    }

    func testBeginResetsSequenceAndThrottle() {
        var pub = LivePartialPublisher()
        let id1 = pub.begin()
        XCTAssertEqual(pub.offer("x", now: 0, at: d0)?.captureID, id1)
        XCTAssertEqual(pub.offer("xy", now: 1, at: d0)?.seq, 2)
        // New capture → fresh id, seq back to 1, throttle clock cleared.
        let id2 = pub.begin()
        XCTAssertNotEqual(id1, id2)
        let p = pub.offer("new", now: 1.001, at: d0)   // would be throttled if clock carried over
        XCTAssertEqual(p?.captureID, id2)
        XCTAssertEqual(p?.seq, 1)
    }

    func testEndStopsFurtherPartials() {
        var pub = LivePartialPublisher()
        _ = pub.begin()
        XCTAssertNotNil(pub.offer("x", now: 0, at: d0))
        pub.end()
        XCTAssertNil(pub.offer("y", now: 10, at: d0))
        XCTAssertNil(pub.final("z", at: d0))
    }
}

// Convenience overload used above so the final call reads naturally in tests.
private extension LivePartialPublisher {
    mutating func final(_ cleaned: String, now: TimeInterval) -> LivePartial? {
        final(cleaned, at: Date(timeIntervalSince1970: 3_000_000))
    }
}
