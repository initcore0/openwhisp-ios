import XCTest
import OpenWhispCore
@testable import SyncCore

/// The pure planner: manifest × manifest → plan. Covers the converged no-op,
/// each section diffing, and the history cursor.
final class SyncPlannerTests: XCTestCase {
    private let planner = SyncPlanner()

    private func manifest(
        vocab: String = "v", profiles: String = "p", modes: String = "m", packs: String = "k",
        historyCount: Int = 0, historyNewestID: UUID? = nil, historyNewestDate: Date? = nil
    ) -> SyncManifest {
        SyncManifest(
            schemaVersion: 3, vocabHash: vocab, profilesHash: profiles, modesHash: modes,
            packsHash: packs,
            historyHead: SyncHistoryHead(count: historyCount, newestID: historyNewestID, newestDate: historyNewestDate)
        )
    }

    func testConvergedIsNoOp() {
        let id = UUID(); let d = Date(timeIntervalSince1970: 100)
        let m = manifest(historyCount: 3, historyNewestID: id, historyNewestDate: d)
        let plan = planner.plan(local: m, remote: m)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertTrue(plan.pull.isEmpty)
        XCTAssertTrue(plan.push.isEmpty)
        XCTAssertNil(plan.historyCursor)
    }

    func testVocabDiffPullsAndPushes() {
        let local = manifest(vocab: "A")
        let remote = manifest(vocab: "B")
        let plan = planner.plan(local: local, remote: remote)
        XCTAssertTrue(plan.pull.contains(.vocabulary))
        XCTAssertTrue(plan.push.contains(.vocabulary))
        XCTAssertFalse(plan.pull.contains(.profiles))
    }

    func testEachConfigSectionDiffsIndependently() {
        for section in [SyncSection.vocabulary, .profiles, .modes, .packs] {
            var remote = manifest()
            switch section {
            case .vocabulary: remote.vocabHash = "X"
            case .profiles:   remote.profilesHash = "X"
            case .modes:      remote.modesHash = "X"
            case .packs:      remote.packsHash = "X"
            case .history:    continue
            }
            let plan = planner.plan(local: manifest(), remote: remote)
            XCTAssertEqual(plan.pull, [section], "pull for \(section)")
            XCTAssertEqual(plan.push, [section], "push for \(section)")
        }
    }

    func testHistoryPullIsAlwaysFullLog() {
        // A correct append-only union pulls the FULL remote log (cursor nil) and
        // dedupes by id — a date cursor would drop older-but-unseen entries.
        let local = manifest(historyCount: 2, historyNewestID: UUID(), historyNewestDate: Date(timeIntervalSince1970: 500))
        let remote = manifest(historyCount: 5, historyNewestID: UUID(), historyNewestDate: Date(timeIntervalSince1970: 900))
        let plan = planner.plan(local: local, remote: remote)
        XCTAssertTrue(plan.pull.contains(.history))
        XCTAssertTrue(plan.push.contains(.history))
        XCTAssertNil(plan.historyCursor, "v1 pulls the full log for a correct id-keyed union")
    }

    func testHistoryPullOnlyWhenLocalEmpty() {
        // Local has no history, remote has some => pull full, no push.
        let local = manifest(historyCount: 0, historyNewestID: nil, historyNewestDate: nil)
        let remote = manifest(historyCount: 3, historyNewestID: UUID(), historyNewestDate: Date(timeIntervalSince1970: 100))
        let plan = planner.plan(local: local, remote: remote)
        XCTAssertTrue(plan.pull.contains(.history))
        XCTAssertNil(plan.historyCursor)          // full log
        XCTAssertFalse(plan.push.contains(.history))
    }

    func testHistoryPushOnlyWhenRemoteEmpty() {
        let local = manifest(historyCount: 4, historyNewestID: UUID(), historyNewestDate: Date(timeIntervalSince1970: 100))
        let remote = manifest(historyCount: 0, historyNewestID: nil, historyNewestDate: nil)
        let plan = planner.plan(local: local, remote: remote)
        XCTAssertFalse(plan.pull.contains(.history))
        XCTAssertTrue(plan.push.contains(.history))
    }

    func testHistorySameHeadIsConverged() {
        let id = UUID(); let d = Date(timeIntervalSince1970: 100)
        let local = manifest(historyCount: 3, historyNewestID: id, historyNewestDate: d)
        let remote = manifest(historyCount: 3, historyNewestID: id, historyNewestDate: d)
        let plan = planner.plan(local: local, remote: remote)
        XCTAssertFalse(plan.pull.contains(.history))
        XCTAssertFalse(plan.push.contains(.history))
    }
}
