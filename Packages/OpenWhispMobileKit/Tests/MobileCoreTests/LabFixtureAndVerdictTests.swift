import XCTest
@testable import MobileCore

final class LabFixtureCatalogTests: XCTestCase {
    func testCatalogHasNineFixtures() {
        XCTAssertEqual(LabFixtureCatalog.all.count, 9)
    }

    func testMultilingualExcludesEnglishAndSilence() {
        let langs = Set(LabFixtureCatalog.multilingual.map(\.language))
        XCTAssertEqual(langs, ["ru", "fr", "de", "es"])
        XCTAssertFalse(LabFixtureCatalog.multilingual.contains { $0.isSilence })
    }

    func testLookupByName() {
        XCTAssertEqual(LabFixtureCatalog.fixture(named: "russian_greeting")?.language, "ru")
        XCTAssertNil(LabFixtureCatalog.fixture(named: "nope"))
    }

    func testSilenceFixtureFlagged() {
        XCTAssertTrue(LabFixtureCatalog.fixture(named: "silence")?.isSilence ?? false)
    }

    func testAppleLocaleMapping() {
        XCTAssertEqual(LabFixtureCatalog.appleLocale(for: "ru"), "ru-RU")
        XCTAssertEqual(LabFixtureCatalog.appleLocale(for: "en"), "en-US")
        XCTAssertEqual(LabFixtureCatalog.appleLocale(for: ""), "en-US")
        XCTAssertEqual(LabFixtureCatalog.appleLocale(for: "fr"), "fr-FR")
    }
}

final class LabVerdictTests: XCTestCase {
    func testOpenWhispWins() {
        let v = LabVerdict.decide(openWhispWER: 0.042, appleWER: 0.118)
        XCTAssertEqual(v.winner, .openWhisp)
        XCTAssertEqual(v.summary, "OpenWhisp WER 4.2% vs Apple 11.8% — OpenWhisp wins.")
    }

    func testAppleWins() {
        let v = LabVerdict.decide(openWhispWER: 0.20, appleWER: 0.05)
        XCTAssertEqual(v.winner, .apple)
        XCTAssertTrue(v.summary.contains("Apple wins here."))
    }

    func testTieWithinHalfPoint() {
        let v = LabVerdict.decide(openWhispWER: 0.100, appleWER: 0.102)
        XCTAssertEqual(v.winner, .tie)
        XCTAssertTrue(v.summary.contains("about even."))
    }

    func testBaselineNotAuthorizedNamesThePermissionGap() {
        let v = LabVerdict.decide(openWhispWER: 0.05, appleWER: nil, baselineReason: .notAuthorized)
        XCTAssertEqual(v.winner, .baselineUnavailable)
        XCTAssertTrue(v.summary.contains("isn't authorized"),
                      "a permission denial must be reported as one: \(v.summary)")
        XCTAssertFalse(v.summary.contains("no on-device model"),
                       "a permission denial must NOT be framed as an Apple coverage gap: \(v.summary)")
    }

    func testBaselineRunFailedCarriesTheError() {
        let v = LabVerdict.decide(openWhispWER: 0.05, appleWER: nil,
                                  baselineReason: .runFailed("recognizer timed out"))
        XCTAssertEqual(v.winner, .baselineUnavailable)
        XCTAssertTrue(v.summary.contains("failed to run"), v.summary)
        XCTAssertTrue(v.summary.contains("recognizer timed out"), v.summary)
        XCTAssertFalse(v.summary.contains("no on-device model"), v.summary)
    }

    func testBaselineUnavailableIsHonest() {
        let v = LabVerdict.decide(openWhispWER: 0.05, appleWER: nil)
        XCTAssertEqual(v.winner, .baselineUnavailable)
        XCTAssertTrue(v.summary.contains("no on-device model"))
        XCTAssertFalse(v.summary.contains("0.0%"), "must not claim a fake 0% for Apple")
    }

    func testOpenWhispFailedNoClaim() {
        let v = LabVerdict.decide(openWhispWER: nil, appleWER: 0.1)
        XCTAssertEqual(v.winner, .tie)
        XCTAssertTrue(v.summary.contains("no result"))
    }
}
