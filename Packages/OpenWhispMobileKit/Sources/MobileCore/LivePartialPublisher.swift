import Foundation

// MARK: - Live-partial publish throttle (ARCHITECTURE §6.8, D12, risk R10b) — pure
//
// The host streams rolling PARTIALS into the App Group while capturing; the keyboard
// polls the slot at 250 ms and renders them at the caret (D12). R10b caps the write
// rate at ≤ 8/s so a chatty engine can't thrash the file store (or the Darwin ping)
// — the store is the truth, the pings are opportunistic, and 8/s is already faster
// than the keyboard's 250 ms poll floor. Each partial carries a monotonic `seq` per
// capture so the keyboard ignores regressions.
//
// The DECISION — "should this partial be written now, and with what seq" — is pure
// and lives here so it is `swift test`-covered without a clock or a file store. The
// `SessionHolder` driver (CaptureKit) owns the actual store write + Darwin ping and
// feeds this its monotonic clock. Two rules the driver relies on:
//
//   - THROTTLE applies to interim partials only. A `.final` (isFinal, the CLEANED
//     text) is ALWAYS written immediately — dropping the final would lose the
//     dictation, and it happens exactly once per capture.
//   - A new capture (`begin`) resets `seq` to 0 and clears the throttle clock, so
//     the first partial of every capture is written without delay.

/// Pure throttle + sequencer for the live-partial stream. One instance per session;
/// `begin(captureID:)` starts a fresh capture, `offer` decides each interim partial,
/// `final` stamps the terminal cleaned partial.
public struct LivePartialPublisher: Equatable, Sendable {

    /// Minimum spacing between interim writes — ≤ 8/s (R10b). 125 ms = exactly 8/s.
    public static let minInterval: TimeInterval = 0.125

    private var captureID: UUID?
    private var seq: Int = 0
    /// The monotonic timestamp of the last INTERIM write, or nil if none yet this
    /// capture (so the first interim partial is never throttled).
    private var lastWriteAt: TimeInterval?
    /// The text of the last partial actually written, to suppress no-op rewrites.
    private var lastText: String?

    public init() {}

    /// Start a new capture: reset the sequence and throttle clock. Returns the
    /// captureID the driver should stamp partials with (a fresh UUID unless one is
    /// supplied, e.g. to match the coordinator's own capture identity).
    public mutating func begin(captureID: UUID = UUID()) -> UUID {
        self.captureID = captureID
        self.seq = 0
        self.lastWriteAt = nil
        self.lastText = nil
        return captureID
    }

    /// Offer an interim partial at monotonic time `now`. Returns the `LivePartial` to
    /// write, or `nil` when this partial is throttled (too soon) or a duplicate of the
    /// last written text. No capture in progress (`begin` not called) → `nil`.
    public mutating func offer(_ text: String, now: TimeInterval, at date: Date) -> LivePartial? {
        guard let captureID else { return nil }
        // Suppress a partial identical to the last one we wrote — the engine can
        // re-emit the same interim text, and a no-op write is pure churn.
        if let lastText, lastText == text { return nil }
        if let lastWriteAt, now - lastWriteAt < Self.minInterval {
            // Within the throttle window: drop this interim. The next accepted
            // partial (or the final) carries the latest text, so nothing is lost —
            // the keyboard only ever needs the newest partial, not every one.
            return nil
        }
        seq += 1
        lastWriteAt = now
        lastText = text
        return LivePartial(captureID: captureID, seq: seq, text: text, isFinal: false, updatedAt: date)
    }

    /// Stamp the terminal CLEANED partial. NEVER throttled — the final happens once
    /// and dropping it would lose the dictation. No capture in progress → `nil`.
    /// `pendingID` is the published `PendingTranscript.id` (§6.8 final-swap
    /// contract): the keyboard consumes it after rendering the final.
    public mutating func final(_ cleaned: String, pendingID: UUID?, at date: Date) -> LivePartial? {
        guard let captureID else { return nil }
        seq += 1
        lastText = cleaned
        return LivePartial(
            captureID: captureID, seq: seq, text: cleaned, isFinal: true,
            updatedAt: date, pendingID: pendingID
        )
    }

    /// End the current capture (clear the identity so stray partials after teardown
    /// are ignored).
    public mutating func end() {
        captureID = nil
        lastText = nil
        lastWriteAt = nil
    }
}
