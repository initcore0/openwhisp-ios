import Foundation

// MARK: - Engine support helpers (ported from OpenWhispCore internals)
//
// A couple of tiny concurrency helpers the mac streaming engines rely on live in
// OpenWhispCore but are `internal` (not part of the public iOS surface). They are
// small and pure, so we port them here rather than block the engine layer on
// another upstream visibility bump. If upstream makes them public, delete these and
// switch to the upstream types.

/// Serializes async operations so they run strictly in enqueue order, each fully
/// completing before the next begins. Ported verbatim from OpenWhispCore's
/// `SerialTaskChain` — the streaming engines use it so a stop's mic teardown always
/// finishes before the next start installs its tap (the "quick double-tap restart"
/// race).
@MainActor
final class SerialTaskChain {
    private var tail: Task<Void, Never> = Task {}
    init() {}

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let prior = tail
        tail = Task {
            await prior.value
            await work()
        }
    }

    /// Await the chain draining to the current tail (all work enqueued so far).
    /// Used by tests.
    func drain() async {
        await tail.value
    }
}
