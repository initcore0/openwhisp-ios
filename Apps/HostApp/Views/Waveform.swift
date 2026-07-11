import SwiftUI

/// A simple live level waveform: a row of bars whose heights follow the recent
/// audio levels fed by `CaptureViewModel.levels` (driven by the coordinator's
/// `onStateChange` listening levels). Purely presentational.
struct Waveform: View {
    /// Recent levels (0…1), newest last.
    var levels: [Float]
    var active: Bool

    private let barCount = 32

    var body: some View {
        GeometryReader { geo in
            let bars = normalizedBars()
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(height: max(3, CGFloat(level) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: levels)
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }

    /// Take the last `barCount` levels, right-aligned, padding the front with a low
    /// idle level so the bar row is always full-width.
    private func normalizedBars() -> [Float] {
        let tail = Array(levels.suffix(barCount))
        let pad = max(0, barCount - tail.count)
        return Array(repeating: 0.04, count: pad) + tail
    }
}
