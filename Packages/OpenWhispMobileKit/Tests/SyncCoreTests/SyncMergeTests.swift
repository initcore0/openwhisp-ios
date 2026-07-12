import XCTest
import OpenWhispCore
@testable import SyncCore

/// The v1 merge policy + its idempotency law. Pure, no I/O.
final class SyncMergeTests: XCTestCase {

    // MARK: - helpers

    private func sub(_ id: UUID, from: String, to: String, at t: TimeInterval, starred: Bool = false) -> Vocabulary.Substitution {
        Vocabulary.Substitution(id: id, from: from, to: to, starred: starred,
                                updatedAt: Date(timeIntervalSince1970: t))
    }
    private func entry(_ id: UUID, _ text: String, at t: TimeInterval) -> TranscriptionEntry {
        TranscriptionEntry(id: id, text: text, date: Date(timeIntervalSince1970: t),
                           appBundleID: nil, appName: nil)
    }
    private func profile(_ id: UUID, _ bundle: String, at t: TimeInterval) -> AppProfile {
        AppProfile(id: id, appBundleID: bundle, displayName: bundle,
                   updatedAt: Date(timeIntervalSince1970: t))
    }

    // MARK: - Vocabulary

    func testVocabUnionByIDNewerWins() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let local = Vocabulary(terms: ["kubectl", "Anthropic"],
                               substitutions: [sub(id1, from: "clod", to: "Claude", at: 100),
                                               sub(id2, from: "a", to: "b", at: 100)])
        let remote = Vocabulary(terms: ["Anthropic", "OpenWhisp"],
                                substitutions: [sub(id1, from: "clod", to: "Claude Code", at: 200),  // newer
                                                sub(id3, from: "x", to: "y", at: 50)])               // new
        let (merged, changed) = SyncMerge.mergeVocabulary(local: local, remote: remote)

        // id1 overwritten by newer, id3 added, id2 kept => 2 changed.
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(merged.substitutions.first(where: { $0.id == id1 })?.to, "Claude Code")
        XCTAssertEqual(Set(merged.substitutions.map(\.id)), [id1, id2, id3])
        // Terms are a set union, local order first.
        XCTAssertEqual(merged.terms, ["kubectl", "Anthropic", "OpenWhisp"])
    }

    func testVocabOlderRemoteLoses() {
        let id1 = UUID()
        let local = Vocabulary(terms: [], substitutions: [sub(id1, from: "a", to: "NEW", at: 200)])
        let remote = Vocabulary(terms: [], substitutions: [sub(id1, from: "a", to: "OLD", at: 100)])
        let (merged, changed) = SyncMerge.mergeVocabulary(local: local, remote: remote)
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(merged.substitutions.first?.to, "NEW")
    }

    func testVocabEqualStampKeepsLocal() {
        let id1 = UUID()
        let local = Vocabulary(terms: [], substitutions: [sub(id1, from: "a", to: "LOCAL", at: 100)])
        let remote = Vocabulary(terms: [], substitutions: [sub(id1, from: "a", to: "REMOTE", at: 100)])
        let (merged, changed) = SyncMerge.mergeVocabulary(local: local, remote: remote)
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(merged.substitutions.first?.to, "LOCAL")
    }

    // MARK: - History

    func testHistoryAppendOnlyUnion() {
        let a = UUID(), b = UUID(), c = UUID()
        let local = [entry(a, "one", at: 300), entry(b, "two", at: 200)]
        let remote = [entry(b, "two-remote", at: 200), entry(c, "three", at: 100)]
        let (merged, added) = SyncMerge.mergeHistory(local: local, remote: remote)
        XCTAssertEqual(added, 1)                          // only c is new
        XCTAssertEqual(merged.count, 3)
        // shared id keeps LOCAL copy
        XCTAssertEqual(merged.first(where: { $0.id == b })?.text, "two")
        // newest-first order
        XCTAssertEqual(merged.map(\.id), [a, b, c])
    }

    // MARK: - Profiles (LWW)

    func testProfilesLWW() {
        let p1 = UUID(), p2 = UUID()
        let local = [profile(p1, "com.slack", at: 100), profile(p2, "com.mail", at: 100)]
        let remote = [profile(p1, "com.slack.NEW", at: 200), profile(UUID(), "com.new", at: 50)]
        let (merged, changed) = SyncMerge.mergeProfiles(local: local, remote: remote)
        XCTAssertEqual(changed, 2)                        // p1 overwritten + 1 new
        XCTAssertEqual(merged.first(where: { $0.id == p1 })?.appBundleID, "com.slack.NEW")
        XCTAssertEqual(merged.count, 3)
    }

    // MARK: - Idempotency law (merge(merge(a,b), b) == merge(a,b))

    func testVocabIdempotent() {
        let id1 = UUID(), id2 = UUID()
        let a = Vocabulary(terms: ["x"], substitutions: [sub(id1, from: "a", to: "A", at: 100)])
        let b = Vocabulary(terms: ["y"], substitutions: [sub(id1, from: "a", to: "A2", at: 200),
                                                          sub(id2, from: "c", to: "C", at: 50)])
        let once = SyncMerge.mergeVocabulary(local: a, remote: b).merged
        let twice = SyncMerge.mergeVocabulary(local: once, remote: b)
        XCTAssertEqual(twice.changed, 0, "second merge must change nothing")
        XCTAssertEqual(Set(twice.merged.substitutions.map(\.id)), Set(once.substitutions.map(\.id)))
        XCTAssertEqual(twice.merged.substitutions.first(where: { $0.id == id1 })?.to, "A2")
        XCTAssertEqual(twice.merged.terms, once.terms)
    }

    func testHistoryIdempotent() {
        let a = UUID(), b = UUID(), c = UUID()
        let l = [entry(a, "one", at: 300)]
        let r = [entry(b, "two", at: 200), entry(c, "three", at: 100)]
        let once = SyncMerge.mergeHistory(local: l, remote: r).merged
        let twice = SyncMerge.mergeHistory(local: once, remote: r)
        XCTAssertEqual(twice.added, 0)
        XCTAssertEqual(twice.merged.map(\.id), once.map(\.id))
    }

    func testProfilesIdempotent() {
        let p1 = UUID()
        let l = [profile(p1, "com.a", at: 100)]
        let r = [profile(p1, "com.a.NEW", at: 200)]
        let once = SyncMerge.mergeProfiles(local: l, remote: r).merged
        let twice = SyncMerge.mergeProfiles(local: once, remote: r)
        XCTAssertEqual(twice.changed, 0)
        XCTAssertEqual(twice.merged, once)
    }
}
