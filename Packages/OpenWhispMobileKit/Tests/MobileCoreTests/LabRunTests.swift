import XCTest
@testable import MobileCore

/// Tests for the Engine Lab run records: the "keep last N" retention rule, the
/// metrics derivations (realtime factor, formatted strings), and the JSON
/// round-trip used for export. Pure — no filesystem.
final class LabRunTests: XCTestCase {

    private func makeRun(name: String, wer: Double? = 0.1, date: Date = Date()) -> LabRun {
        LabRun(
            date: date,
            engineName: name,
            engineKind: .parakeet,
            modelID: "parakeet-unified-320ms",
            fixtureName: "plain_speech",
            isLive: false,
            language: "en",
            reference: "the quick brown fox",
            hypothesis: "the quick brown box",
            wer: wer,
            metrics: LabMetrics(latencySeconds: 0.5, audioSeconds: 2.0, peakRSSDeltaBytes: 50 * 1024 * 1024)
        )
    }

    // MARK: - Retention

    func testAppendingPrependsNewest() {
        let a = makeRun(name: "a")
        let b = makeRun(name: "b")
        let log = LabRunLog.appending(b, to: [a])
        XCTAssertEqual(log.map(\.engineName), ["b", "a"], "newest run is first")
    }

    func testAppendingTrimsToLimit() {
        var log: [LabRun] = []
        for i in 0..<10 {
            log = LabRunLog.appending(makeRun(name: "run\(i)"), to: log, limit: 5)
        }
        XCTAssertEqual(log.count, 5, "log bounded to the limit")
        XCTAssertEqual(log.first?.engineName, "run9", "newest kept")
        XCTAssertEqual(log.last?.engineName, "run5", "oldest-within-window kept, older dropped")
    }

    func testDefaultLimitIsMaxRuns() {
        var log: [LabRun] = []
        for i in 0..<(LabRunLog.maxRuns + 5) {
            log = LabRunLog.appending(makeRun(name: "r\(i)"), to: log)
        }
        XCTAssertEqual(log.count, LabRunLog.maxRuns)
    }

    // MARK: - Metrics

    func testRealtimeFactor() {
        let m = LabMetrics(latencySeconds: 1.0, audioSeconds: 4.0, peakRSSDeltaBytes: 0)
        XCTAssertEqual(m.realtimeFactor, 0.25)
        XCTAssertEqual(m.realtimeFactorString, "0.25×")
    }

    func testRealtimeFactorNilWhenNoAudio() {
        let m = LabMetrics(latencySeconds: 1.0, audioSeconds: 0, peakRSSDeltaBytes: 0)
        XCTAssertNil(m.realtimeFactor)
        XCTAssertEqual(m.realtimeFactorString, "—")
    }

    func testPeakRSSFormatting() {
        let m = LabMetrics(latencySeconds: 1, audioSeconds: 1, peakRSSDeltaBytes: 100 * 1024 * 1024)
        XCTAssertEqual(m.peakRSSDeltaString, "100 MB")
        let none = LabMetrics(latencySeconds: 1, audioSeconds: 1, peakRSSDeltaBytes: 0)
        XCTAssertEqual(none.peakRSSDeltaString, "—")
    }

    func testWERPercentStringAndNil() {
        XCTAssertEqual(makeRun(name: "x", wer: 0.042).werPercentString, "4.2%")
        XCTAssertEqual(makeRun(name: "x", wer: nil).werPercentString, "—")
    }

    // MARK: - JSON round-trip (export)

    func testJSONRoundTrip() throws {
        let runs = [makeRun(name: "a", date: Date(timeIntervalSince1970: 1_700_000_000)),
                    makeRun(name: "b", date: Date(timeIntervalSince1970: 1_700_000_100))]
        let data = try LabRunLog.encode(runs)
        let back = try LabRunLog.decode(data)
        XCTAssertEqual(back.count, 2)
        XCTAssertEqual(back.map(\.engineName), ["a", "b"])
        XCTAssertEqual(back.first?.metrics.audioSeconds, 2.0)
        XCTAssertEqual(back.first?.wer, 0.1)
    }

    func testEncodedJSONIsPrettyAndStable() throws {
        let data = try LabRunLog.encode([makeRun(name: "a", date: Date(timeIntervalSince1970: 0))])
        let str = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(str.contains("\n"), "pretty-printed JSON has newlines")
        XCTAssertTrue(str.contains("\"engineName\""))
    }
}
