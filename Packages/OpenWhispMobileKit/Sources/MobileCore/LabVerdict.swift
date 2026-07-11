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
    /// baseline could not run on-device for the locale (unavailable), which the
    /// product frames as an OpenWhisp advantage but reports honestly rather than
    /// claiming a bogus 0%.
    public static func decide(openWhispWER: Double?, appleWER: Double?) -> LabVerdict {
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
            return LabVerdict(
                winner: .baselineUnavailable,
                openWhispWER: ow,
                appleWER: nil,
                summary: "OpenWhisp WER \(pct(ow)) — Apple has no on-device model for this language, so it can't run at all."
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
