import Foundation

// MARK: - Side-by-side verdict (Engine Lab compare mode, WP3)
//
// The Lab's compare mode runs the SAME fixture through an OpenWhisp engine AND the
// Apple baseline, then states a one-line verdict: "OpenWhisp WER 4.2% vs Apple
// 11.8% — OpenWhisp wins." That sentence is the product's Goal-#1 claim in
// miniature, so its logic (who won, by how much, and the honest "baseline couldn't
// run here" case) is pure and tested, not buried in a view.

/// The outcome of comparing an OpenWhisp engine against the Apple baseline on one
/// fixture.
public struct LabVerdict: Equatable, Sendable {
    public enum Winner: Equatable, Sendable {
        case openWhisp
        case apple
        case tie
        /// Apple's on-device recognizer couldn't run for this locale — itself a
        /// data point for the multilingual coverage-gap story.
        case baselineUnavailable
    }

    /// WHY the Apple baseline produced no WER. The verdict sentence is the
    /// product's Goal-#1 claim, so it must state the true reason — "Apple has no
    /// model" when permission was simply denied would be a lie.
    public enum BaselineUnavailableReason: Equatable, Sendable {
        /// Apple ships no on-device model for this locale (the multilingual
        /// coverage-gap story — a legitimate OpenWhisp advantage).
        case noOnDeviceModel
        /// Speech-recognition permission is not granted on this device.
        case notAuthorized
        /// The recognizer exists but the run failed.
        case runFailed(String)
    }

    public let winner: Winner
    /// OpenWhisp's WER (fraction), nil if that run errored/has no reference.
    public let openWhispWER: Double?
    /// Apple's WER (fraction), nil if the baseline couldn't run.
    public let appleWER: Double?
    /// The full one-line verdict string for the UI.
    public let summary: String

    public init(winner: Winner, openWhispWER: Double?, appleWER: Double?, summary: String) {
        self.winner = winner
        self.openWhispWER = openWhispWER
        self.appleWER = appleWER
        self.summary = summary
    }

    /// Decide the verdict from two WER fractions. `appleWER == nil` means the
    /// baseline produced no score; `baselineReason` says WHY, and the summary
    /// states that reason honestly rather than claiming a coverage gap (or a
    /// bogus 0%) when the truth is a permission denial or a plain failure.
    public static func decide(
        openWhispWER: Double?,
        appleWER: Double?,
        baselineReason: BaselineUnavailableReason = .noOnDeviceModel
    ) -> LabVerdict {
        func pct(_ w: Double?) -> String { w.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }

        // OpenWhisp's own run failed → no claim.
        guard let ow = openWhispWER else {
            return LabVerdict(
                winner: .tie,
                openWhispWER: nil,
                appleWER: appleWER,
                summary: "OpenWhisp produced no result to compare."
            )
        }

        guard let ap = appleWER else {
            let reasonText: String
            switch baselineReason {
            case .noOnDeviceModel:
                reasonText = "Apple has no on-device model for this language, so it can't run at all."
            case .notAuthorized:
                reasonText = "the Apple baseline didn't run — speech recognition isn't authorized on this device (Settings › Privacy & Security › Speech Recognition)."
            case .runFailed(let message):
                reasonText = "the Apple baseline failed to run: \(message)"
            }
            return LabVerdict(
                winner: .baselineUnavailable,
                openWhispWER: ow,
                appleWER: nil,
                summary: "OpenWhisp WER \(pct(ow)) — \(reasonText)"
            )
        }

        let winner: Winner
        let tail: String
        // Treat a <0.5-point gap as a tie so noise doesn't manufacture a winner.
        if abs(ow - ap) < 0.005 {
            winner = .tie
            tail = "about even."
        } else if ow < ap {
            winner = .openWhisp
            tail = "OpenWhisp wins."
        } else {
            winner = .apple
            tail = "Apple wins here."
        }

        return LabVerdict(
            winner: winner,
            openWhispWER: ow,
            appleWER: ap,
            summary: "OpenWhisp WER \(pct(ow)) vs Apple \(pct(ap)) — \(tail)"
        )
    }
}
