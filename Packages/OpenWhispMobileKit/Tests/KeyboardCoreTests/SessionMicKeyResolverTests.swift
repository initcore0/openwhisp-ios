import XCTest
@testable import KeyboardCore
import MobileCore

/// Truth table for the session-aware mic-key resolver. It must (a) gate on Full
/// Access exactly like the floor flow, (b) drive the key off the live session
/// phase AFTER the 30 s staleness fence, and (c) fall back to the UNCHANGED floor
/// flow (`MicKeyResolver.resolve`) whenever no session is live.
final class SessionMicKeyResolverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func sessionStatus(_ phase: SessionStatus.Phase, updatedAt: Date? = nil) -> SessionStatus {
        SessionStatus(phase: phase, sessionID: UUID(), armedAt: now, expiresAt: nil,
                      updatedAt: updatedAt ?? now)
    }

    private func fresh(id: UUID = UUID()) -> PendingTranscript {
        PendingTranscript(id: id, text: "hi", createdAt: now, source: .inApp)
    }

    // MARK: Full Access off dominates everything

    func testFullAccessOffAlwaysExplains() {
        for phase in [SessionStatus.Phase.off, .armed, .capturing, .transcribing] {
            let got = MicKeyResolver.resolveSession(
                fullAccess: false, sessionStatus: sessionStatus(phase),
                captureState: .idle, pending: fresh(), now: now
            )
            XCTAssertEqual(got, .explainFullAccess, "phase=\(phase) with FA off must explain")
        }
    }

    // MARK: Live phases drive the key

    func testArmedStartsCapture() {
        let got = MicKeyResolver.resolveSession(
            fullAccess: true, sessionStatus: sessionStatus(.armed),
            captureState: .idle, pending: nil, now: now
        )
        XCTAssertEqual(got, .startCapture)
    }

    func testCapturingStopsCapture() {
        let got = MicKeyResolver.resolveSession(
            fullAccess: true, sessionStatus: sessionStatus(.capturing),
            captureState: .capturing, pending: nil, now: now
        )
        XCTAssertEqual(got, .stopCapture)
    }

    func testTranscribingShowsTranscribing() {
        let got = MicKeyResolver.resolveSession(
            fullAccess: true, sessionStatus: sessionStatus(.transcribing),
            captureState: .transcribing, pending: nil, now: now
        )
        XCTAssertEqual(got, .showTranscribing)
    }

    // MARK: Staleness fence — a dead host collapses to the floor flow

    func testStaleArmedFallsBackToFloorFlow() {
        // armed but heartbeat 31 s old → effectivePhase .off → floor flow.
        let stale = sessionStatus(.armed, updatedAt: now.addingTimeInterval(-(SessionStatus.stalenessWindow + 1)))
        let id = UUID()
        let got = MicKeyResolver.resolveSession(
            fullAccess: true, sessionStatus: stale,
            captureState: .idle, pending: fresh(id: id), now: now
        )
        XCTAssertEqual(got, .startSessionHop(.insertPending(id: id)),
                       "a stale (dead-host) session behaves as no session")
    }

    // MARK: No session → floor flow, unchanged

    func testOffDelegatesToFloorFlowInsertPending() {
        let id = UUID()
        let got = MicKeyResolver.resolveSession(
            fullAccess: true, sessionStatus: sessionStatus(.off),
            captureState: .idle, pending: fresh(id: id), now: now
        )
        XCTAssertEqual(got, .startSessionHop(.insertPending(id: id)))
    }

    func testOffDelegatesToFloorFlowShowCaptureUX() {
        let got = MicKeyResolver.resolveSession(
            fullAccess: true, sessionStatus: sessionStatus(.off),
            captureState: .idle, pending: nil, now: now
        )
        XCTAssertEqual(got, .startSessionHop(.showCaptureUX))
    }

    func testOffDelegatesToFloorFlowShowCapturing() {
        // No session, but the (WP5) floor-flow capture is running.
        let got = MicKeyResolver.resolveSession(
            fullAccess: true, sessionStatus: sessionStatus(.off),
            captureState: .capturing, pending: nil, now: now
        )
        XCTAssertEqual(got, .startSessionHop(.showCapturing))
    }

    // MARK: Exhaustive truth table

    func testFullTruthTable() {
        enum SessionKind: CaseIterable { case off, armed, capturing, transcribing, staleArmed }
        enum PendingKind: CaseIterable { case none, fresh }
        let id = UUID()

        func status(_ k: SessionKind) -> SessionStatus {
            switch k {
            case .off: return sessionStatus(.off)
            case .armed: return sessionStatus(.armed)
            case .capturing: return sessionStatus(.capturing)
            case .transcribing: return sessionStatus(.transcribing)
            case .staleArmed:
                return sessionStatus(.armed, updatedAt: now.addingTimeInterval(-(SessionStatus.stalenessWindow + 1)))
            }
        }
        func pending(_ k: PendingKind) -> PendingTranscript? {
            k == .fresh ? fresh(id: id) : nil
        }

        func expected(fullAccess: Bool, session: SessionKind, capture: HandoffCaptureState, pending pk: PendingKind) -> SessionMicKeyBehavior {
            if !fullAccess { return .explainFullAccess }
            switch session {
            case .armed: return .startCapture
            case .capturing: return .stopCapture
            case .transcribing: return .showTranscribing
            case .off, .staleArmed:
                // floor flow (staleArmed collapses to off via the fence)
                let floor = MicKeyResolver.resolve(
                    fullAccess: true, captureState: capture, pending: pending(pk), now: now)
                return .startSessionHop(floor)
            }
        }

        var checked = 0
        for fullAccess in [true, false] {
            for session in SessionKind.allCases {
                for capture in [HandoffCaptureState.idle, .capturing, .transcribing] {
                    for pk in PendingKind.allCases {
                        let got = MicKeyResolver.resolveSession(
                            fullAccess: fullAccess, sessionStatus: status(session),
                            captureState: capture, pending: pending(pk), now: now)
                        let want = expected(fullAccess: fullAccess, session: session, capture: capture, pending: pk)
                        XCTAssertEqual(got, want,
                                       "fa=\(fullAccess) session=\(session) capture=\(capture) pending=\(pk)")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertEqual(checked, 2 * 5 * 3 * 2)
    }
}
