import XCTest
@testable import KeyboardCore
import MobileCore

final class MicKeyResolverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func fresh(id: UUID = UUID()) -> PendingTranscript {
        // createdAt = now → expiresAt = now + 120, unexpired at `now`.
        PendingTranscript(id: id, text: "hi", createdAt: now, source: .inApp)
    }

    private func expired(id: UUID = UUID()) -> PendingTranscript {
        // createdAt well in the past → already expired at `now`.
        PendingTranscript(id: id, text: "hi", createdAt: now.addingTimeInterval(-200), source: .inApp)
    }

    // MARK: Full Access off dominates everything

    func testFullAccessOffAlwaysExplains() {
        let states: [HandoffCaptureState] = [.idle, .capturing, .transcribing]
        let pendings: [PendingTranscript?] = [nil, fresh(), expired()]
        for s in states {
            for p in pendings {
                let behavior = MicKeyResolver.resolve(
                    fullAccess: false, captureState: s, pending: p, now: now
                )
                XCTAssertEqual(behavior, .explainFullAccess,
                               "fullAccess=false, state=\(s), pending=\(String(describing: p?.id)) should explain")
            }
        }
    }

    // MARK: Capture in flight → showCapturing (even with a stale pending)

    func testCapturingShowsCapturingRegardlessOfPending() {
        for s in [HandoffCaptureState.capturing, .transcribing] {
            for p in [nil, fresh(), expired()] as [PendingTranscript?] {
                let behavior = MicKeyResolver.resolve(
                    fullAccess: true, captureState: s, pending: p, now: now
                )
                XCTAssertEqual(behavior, .showCapturing,
                               "state=\(s) should show capturing regardless of pending")
            }
        }
    }

    // MARK: Idle + fresh pending → insertPending

    func testIdleWithFreshPendingInserts() {
        let id = UUID()
        let behavior = MicKeyResolver.resolve(
            fullAccess: true, captureState: .idle, pending: fresh(id: id), now: now
        )
        XCTAssertEqual(behavior, .insertPending(id: id))
    }

    // MARK: Idle + expired pending → showCaptureUX

    func testIdleWithExpiredPendingShowsCaptureUX() {
        let behavior = MicKeyResolver.resolve(
            fullAccess: true, captureState: .idle, pending: expired(), now: now
        )
        XCTAssertEqual(behavior, .showCaptureUX)
    }

    // MARK: Idle + no pending → showCaptureUX

    func testIdleWithNoPendingShowsCaptureUX() {
        let behavior = MicKeyResolver.resolve(
            fullAccess: true, captureState: .idle, pending: nil, now: now
        )
        XCTAssertEqual(behavior, .showCaptureUX)
    }

    // MARK: Exhaustive truth table (fullAccess × state × pending-kind)

    func testFullTruthTable() {
        enum PendingKind: CaseIterable { case none, fresh, expired }
        let id = UUID()

        func pending(_ k: PendingKind) -> PendingTranscript? {
            switch k {
            case .none: return nil
            case .fresh: return fresh(id: id)
            case .expired: return expired(id: id)
            }
        }

        func expected(fullAccess: Bool, state: HandoffCaptureState, kind: PendingKind) -> MicKeyBehavior {
            if !fullAccess { return .explainFullAccess }
            if state == .capturing || state == .transcribing { return .showCapturing }
            // idle
            switch kind {
            case .fresh: return .insertPending(id: id)
            case .none, .expired: return .showCaptureUX
            }
        }

        var checked = 0
        for fullAccess in [true, false] {
            for state in [HandoffCaptureState.idle, .capturing, .transcribing] {
                for kind in PendingKind.allCases {
                    let got = MicKeyResolver.resolve(
                        fullAccess: fullAccess, captureState: state,
                        pending: pending(kind), now: now
                    )
                    let want = expected(fullAccess: fullAccess, state: state, kind: kind)
                    XCTAssertEqual(got, want,
                                   "fullAccess=\(fullAccess) state=\(state) kind=\(kind)")
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 2 * 3 * 3, "should have covered the whole table")
    }
}
