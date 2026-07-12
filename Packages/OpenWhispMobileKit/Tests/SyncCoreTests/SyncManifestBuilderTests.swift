import XCTest
import OpenWhispCore
@testable import SyncCore

/// The manifest builder: deterministic content hashes, order-insensitivity, and
/// the end-to-end law that two converged states plan to a no-op.
final class SyncManifestBuilderTests: XCTestCase {

    private func sub(_ from: String, _ to: String, at t: TimeInterval) -> Vocabulary.Substitution {
        Vocabulary.Substitution(from: from, to: to, updatedAt: Date(timeIntervalSince1970: t))
    }

    func testSameContentSameHash() {
        let v = Vocabulary(terms: ["a", "b"], substitutions: [sub("x", "y", at: 1)])
        let m1 = SyncManifestBuilder.manifest(for: .init(vocabulary: v))
        let m2 = SyncManifestBuilder.manifest(for: .init(vocabulary: v))
        XCTAssertEqual(m1.vocabHash, m2.vocabHash)
    }

    func testTermOrderDoesNotChangeHash() {
        let a = Vocabulary(terms: ["a", "b", "c"], substitutions: [])
        let b = Vocabulary(terms: ["c", "a", "b"], substitutions: [])
        XCTAssertEqual(
            SyncManifestBuilder.vocabHash(a),
            SyncManifestBuilder.vocabHash(b),
            "reorder of the same terms must not force a sync"
        )
    }

    func testDifferentContentDifferentHash() {
        let a = Vocabulary(terms: ["a"], substitutions: [])
        let b = Vocabulary(terms: ["a", "b"], substitutions: [])
        XCTAssertNotEqual(SyncManifestBuilder.vocabHash(a), SyncManifestBuilder.vocabHash(b))
    }

    func testHistoryHead() {
        let old = TranscriptionEntry(text: "old", date: Date(timeIntervalSince1970: 100), appBundleID: nil, appName: nil)
        let new = TranscriptionEntry(text: "new", date: Date(timeIntervalSince1970: 300), appBundleID: nil, appName: nil)
        let head = SyncManifestBuilder.historyHead([old, new])
        XCTAssertEqual(head.count, 2)
        XCTAssertEqual(head.newestID, new.id)
        XCTAssertEqual(head.newestDate, new.date)
    }

    func testConvergedStatePlansNoOp() {
        let v = Vocabulary(terms: ["kubectl"], substitutions: [sub("clod", "Claude", at: 5)])
        let e = TranscriptionEntry(text: "hi", date: Date(timeIntervalSince1970: 10), appBundleID: nil, appName: nil)
        let state = SyncManifestBuilder.LocalState(vocabulary: v, history: [e])
        let m = SyncManifestBuilder.manifest(for: state)
        let plan = SyncPlanner().plan(local: m, remote: m)
        XCTAssertTrue(plan.isNoOp)
    }

    func testDivergentVocabPlansSync() {
        let base = Vocabulary(terms: ["a"], substitutions: [])
        let other = Vocabulary(terms: ["a", "b"], substitutions: [])
        let ml = SyncManifestBuilder.manifest(for: .init(vocabulary: base))
        let mr = SyncManifestBuilder.manifest(for: .init(vocabulary: other))
        let plan = SyncPlanner().plan(local: ml, remote: mr)
        XCTAssertTrue(plan.pull.contains(.vocabulary))
        XCTAssertTrue(plan.push.contains(.vocabulary))
    }
}
