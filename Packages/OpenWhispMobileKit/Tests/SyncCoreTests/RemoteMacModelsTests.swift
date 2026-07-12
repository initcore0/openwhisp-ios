import XCTest
import OpenWhispCore
@testable import SyncCore

/// Pure mapping of the Mac's history + dictate-lifecycle wire shapes into the
/// phone's display models. Covers timestamp round-trip, initiator normalization,
/// app-label fallback, empty/edge results, and the dictate-state fold.
final class RemoteMacModelsTests: XCTestCase {

    private func dto(
        id: UUID = UUID(), text: String = "hi", date: String,
        appBundleID: String? = nil, appName: String? = nil, initiator: String? = nil
    ) -> BridgeWire.HistoryEntryDTO {
        BridgeWire.HistoryEntryDTO(
            id: id, text: text, date: date, appBundleID: appBundleID,
            appName: appName, initiator: initiator)
    }

    // MARK: History mapping

    /// The Mac encodes dates with `BridgeWire.iso8601String` (fractional seconds);
    /// a round-trip through the display model must recover the same instant.
    func testDateRoundTripsFromWireEncoding() {
        let when = Date(timeIntervalSince1970: 1_700_000_000.5)
        let item = RemoteHistoryItem(dto: dto(date: BridgeWire.iso8601String(from: when)))
        XCTAssertNotNil(item.date)
        XCTAssertEqual(item.date!.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.01)
    }

    /// A plain (non-fractional) ISO-8601 string still parses (tolerant).
    func testPlainISO8601Parses() {
        let item = RemoteHistoryItem(dto: dto(date: "2026-07-12T10:00:00Z"))
        XCTAssertNotNil(item.date)
    }

    func testEmptyOrGarbageDateYieldsNilButKeepsRow() {
        XCTAssertNil(RemoteHistoryItem(dto: dto(date: "")).date)
        XCTAssertNil(RemoteHistoryItem(dto: dto(date: "not-a-date")).date)
        // The row is still present with its text.
        XCTAssertEqual(RemoteHistoryItem(dto: dto(text: "kept", date: "")).text, "kept")
    }

    func testInitiatorNormalization() {
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", initiator: "user")).initiator, .user)
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", initiator: "agent")).initiator, .agent)
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", initiator: "AGENT")).initiator, .agent)
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", initiator: nil)).initiator, .unknown)
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", initiator: "weird")).initiator, .unknown)
    }

    func testAppLabelPrefersNameThenBundleThenNil() {
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", appBundleID: "com.a", appName: "Notes")).appLabel, "Notes")
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", appBundleID: "com.a", appName: nil)).appLabel, "com.a")
        XCTAssertEqual(RemoteHistoryItem(dto: dto(date: "", appBundleID: "com.a", appName: "")).appLabel, "com.a")
        XCTAssertNil(RemoteHistoryItem(dto: dto(date: "", appBundleID: nil, appName: nil)).appLabel)
    }

    func testListPreservesOrderAndCount() {
        let a = dto(text: "first", date: "")
        let b = dto(text: "second", date: "")
        let items = RemoteHistoryItem.list(from: .init(entries: [a, b]))
        XCTAssertEqual(items.map(\.text), ["first", "second"])
    }

    func testEmptyHistoryResultMapsToEmpty() {
        XCTAssertTrue(RemoteHistoryItem.list(from: .init(entries: [])).isEmpty)
    }

    func testIDCarriesThrough() {
        let id = UUID()
        XCTAssertEqual(RemoteHistoryItem(dto: dto(id: id, date: "")).id, id)
    }

    // MARK: Dictate-phase fold

    func testWireStateFoldsToPhase() {
        XCTAssertEqual(RemoteDictationPhase.from(wire: .consentPending), .requesting)
        XCTAssertEqual(RemoteDictationPhase.from(wire: .starting), .requesting)
        XCTAssertEqual(RemoteDictationPhase.from(wire: .listening), .listening)
        XCTAssertEqual(RemoteDictationPhase.from(wire: .transcribing), .working)
        XCTAssertEqual(RemoteDictationPhase.from(wire: .refining), .working)
    }

    func testPhaseBusyFlag() {
        XCTAssertTrue(RemoteDictationPhase.requesting.isBusy)
        XCTAssertTrue(RemoteDictationPhase.listening.isBusy)
        XCTAssertTrue(RemoteDictationPhase.working.isBusy)
        XCTAssertFalse(RemoteDictationPhase.idle.isBusy)
        XCTAssertFalse(RemoteDictationPhase.finished(text: "x").isBusy)
        XCTAssertFalse(RemoteDictationPhase.failed(.macBusy).isBusy)
    }
}
