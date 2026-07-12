import XCTest
@testable import MobileCore

/// The deep-link parser is the floor-flow entry point (ARCHITECTURE §5.2). It must
/// be total: every URL maps to exactly one `DeepLink`, `openwhisp://dictate` is the
/// only side-effectful route, and everything else is `.unknown` (never a crash,
/// never a wrong route).
final class DeepLinkTests: XCTestCase {

    func testDictateHost() {
        XCTAssertEqual(DeepLink.parse(URL(string: "openwhisp://dictate")!), .dictate)
    }

    func testDictateIsCaseInsensitiveOnSchemeAndHost() {
        XCTAssertEqual(DeepLink.parse(URL(string: "OpenWhisp://Dictate")!), .dictate)
        XCTAssertEqual(DeepLink.parse(URL(string: "OPENWHISP://DICTATE")!), .dictate)
    }

    func testDictateIgnoresExtraPathAndQuery() {
        XCTAssertEqual(DeepLink.parse(URL(string: "openwhisp://dictate/now?src=action")!), .dictate)
    }

    func testUnknownHostIsUnknown() {
        let url = "openwhisp://settings"
        XCTAssertEqual(DeepLink.parse(URL(string: url)!), .unknown(url))
    }

    func testForeignSchemeIsUnknown() {
        let url = "https://openwhisp.app/dictate"
        XCTAssertEqual(DeepLink.parse(URL(string: url)!), .unknown(url))
    }

    func testHostlessURLIsUnknown() {
        // No host at all (just a path) — must not route to dictate.
        let url = "openwhisp:dictate"
        let parsed = DeepLink.parse(URL(string: url)!)
        if case .unknown = parsed {} else {
            XCTFail("expected .unknown for hostless URL, got \(parsed)")
        }
    }

    func testStringOverloadParsesAndRejects() {
        XCTAssertEqual(DeepLink.parse("openwhisp://dictate"), .dictate)
        // A string that is not a valid URL is .unknown, not a crash.
        if case .unknown = DeepLink.parse("") {} else {
            XCTFail("empty string must be .unknown")
        }
    }

    func testCanonicalURLRoundTrips() {
        // dictate's canonical URL parses back to dictate; unknown has no URL.
        let url = DeepLink.dictate.url
        XCTAssertNotNil(url)
        XCTAssertEqual(DeepLink.parse(url!), .dictate)
        XCTAssertNil(DeepLink.unknown("x").url)
    }
}
