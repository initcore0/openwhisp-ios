import XCTest
import OpenWhispCore
import SyncCore
@testable import SyncKit

/// SyncEngine end-to-end against the in-process ``FakeSyncPeer`` — proves the
/// full manifest → plan → pull/push → apply loop and two-way convergence +
/// idempotency, with no network.
final class SyncEngineTests: XCTestCase {

    private func sub(_ from: String, _ to: String, at t: TimeInterval) -> Vocabulary.Substitution {
        Vocabulary.Substitution(from: from, to: to, updatedAt: Date(timeIntervalSince1970: t))
    }
    private func entry(_ text: String, at t: TimeInterval) -> TranscriptionEntry {
        TranscriptionEntry(text: text, date: Date(timeIntervalSince1970: t), appBundleID: nil, appName: nil)
    }

    func testTwoWaySyncConvergesBothSides() throws {
        // Phone has vocab A + history H1; Mac has vocab B + history H2. After a
        // sync, BOTH sides should hold A+B and H1+H2.
        let phoneVocab = Vocabulary(terms: ["phone"], substitutions: [sub("a", "A", at: 100)])
        let macVocab = Vocabulary(terms: ["mac"], substitutions: [sub("b", "B", at: 100)])
        let h1 = entry("phone note", at: 300)
        let h2 = entry("mac note", at: 200)

        let store = InMemorySyncStore(vocabulary: phoneVocab, history: [h1])
        let peer = FakeSyncPeer(vocabulary: macVocab, history: [h2])
        let engine = SyncEngine(store: store)

        let report = try engine.run(with: peer)

        // Phone pulled Mac's substitution + Mac's history entry.
        XCTAssertEqual(report.pulled.vocabulary, 1)
        XCTAssertEqual(report.pulled.history, 1)
        // Mac merged the phone's push.
        XCTAssertGreaterThanOrEqual(report.pushed.vocabulary, 1)
        XCTAssertGreaterThanOrEqual(report.pushed.history, 1)

        // Phone now has both subs + both terms + both history entries.
        XCTAssertEqual(Set(store.vocabulary.substitutions.map(\.to)), ["A", "B"])
        XCTAssertEqual(Set(store.vocabulary.terms), ["phone", "mac"])
        XCTAssertEqual(Set(store.history.map(\.id)), [h1.id, h2.id])

        // Mac now has both too.
        XCTAssertEqual(Set(peer.vocabulary.substitutions.map(\.to)), ["A", "B"])
        XCTAssertEqual(Set(peer.history.map(\.id)), [h1.id, h2.id])
    }

    func testHistoryPullWalksEveryPage() throws {
        // The Mac holds 25 history entries; it pages at 4 per frame (frame-cap
        // safety). The engine must re-pull until drained and end up with ALL 25 —
        // proving the paging loop, not a single-frame pull that would truncate.
        let macEntries = (0..<25).map { entry("mac-\($0)", at: TimeInterval(1_000 + $0)) }
        let store = InMemorySyncStore(vocabulary: Vocabulary(terms: [], substitutions: []), history: [])
        let peer = FakeSyncPeer(vocabulary: Vocabulary(terms: [], substitutions: []), history: macEntries)
        peer.historyPageSize = 4
        let engine = SyncEngine(store: store)

        let report = try engine.run(with: peer)

        XCTAssertEqual(store.history.count, 25, "every paged entry must land locally")
        XCTAssertEqual(Set(store.history.map(\.id)), Set(macEntries.map(\.id)))
        XCTAssertEqual(report.pulled.history, 25, "report counts all pulled pages")
    }

    func testHistoryPullPagingIsIdempotent() throws {
        let macEntries = (0..<10).map { entry("m-\($0)", at: TimeInterval(2_000 + $0)) }
        let store = InMemorySyncStore(vocabulary: Vocabulary(terms: [], substitutions: []), history: [])
        let peer = FakeSyncPeer(vocabulary: Vocabulary(terms: [], substitutions: []), history: macEntries)
        peer.historyPageSize = 3
        let engine = SyncEngine(store: store)
        _ = try engine.run(with: peer)
        let secondReport = try engine.run(with: peer)
        XCTAssertEqual(store.history.count, 10)
        XCTAssertEqual(secondReport.pulled.history, 0, "a second paged sync adds nothing")
    }

    func testSecondSyncIsNoOp() throws {
        let store = InMemorySyncStore(
            vocabulary: Vocabulary(terms: ["x"], substitutions: [sub("a", "A", at: 100)]),
            history: [entry("n", at: 100)])
        let peer = FakeSyncPeer(
            vocabulary: Vocabulary(terms: ["y"], substitutions: [sub("b", "B", at: 100)]),
            history: [entry("m", at: 50)])
        let engine = SyncEngine(store: store)

        let first = try engine.run(with: peer)
        XCTAssertTrue(first.didAnything)

        let second = try engine.run(with: peer)
        XCTAssertFalse(second.didAnything, "a converged re-sync must move nothing")
        XCTAssertEqual(second.pulled.total, 0)
        XCTAssertEqual(second.pushed.total, 0)
    }

    func testNewerRemoteEditWins() throws {
        let id = UUID()
        // Same substitution id, phone's is older, Mac's is newer → phone adopts Mac's.
        let phoneSub = Vocabulary.Substitution(id: id, from: "clod", to: "OLD", updatedAt: Date(timeIntervalSince1970: 100))
        let macSub = Vocabulary.Substitution(id: id, from: "clod", to: "NEW", updatedAt: Date(timeIntervalSince1970: 200))
        let store = InMemorySyncStore(vocabulary: Vocabulary(terms: [], substitutions: [phoneSub]))
        let peer = FakeSyncPeer(vocabulary: Vocabulary(terms: [], substitutions: [macSub]))
        let engine = SyncEngine(store: store)

        _ = try engine.run(with: peer)
        XCTAssertEqual(store.vocabulary.substitutions.first(where: { $0.id == id })?.to, "NEW")
    }

    func testEmptyPeerNoOp() throws {
        let store = InMemorySyncStore(vocabulary: Vocabulary(terms: ["x"], substitutions: []))
        let peer = FakeSyncPeer(vocabulary: Vocabulary(terms: ["x"], substitutions: []))
        let engine = SyncEngine(store: store)
        let report = try engine.run(with: peer)
        XCTAssertFalse(report.didAnything)
    }

    func testHistoryOnlyPullWhenPhoneEmpty() throws {
        // Phone has NO history, Mac has two entries → phone pulls both, pushes none.
        let store = InMemorySyncStore()
        let peer = FakeSyncPeer(history: [entry("a", at: 200), entry("b", at: 100)])
        let engine = SyncEngine(store: store)
        let report = try engine.run(with: peer)
        XCTAssertEqual(report.pulled.history, 2)
        XCTAssertEqual(report.pushed.history, 0)
        XCTAssertEqual(store.history.count, 2)
    }
}
