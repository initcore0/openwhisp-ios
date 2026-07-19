import Foundation
import MobileCore
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Owns the dictation Live Activity lifecycle from the host app (ARCHITECTURE §5.1
/// hero surfaces). A thin, single-instance wrapper around ActivityKit that the
/// capture view models drive with the pure `DictationActivityState`:
///
///   start(trigger:)  — request the activity as capture begins.
///   update(_:)       — push a new content state (listening level, transcribing…).
///   finish()         — show the terminal "Inserted" state, then end after a beat.
///   end()            — end immediately (cancel / failure).
///
/// Everything is best-effort and guarded: Live Activities may be disabled by the
/// user or unavailable on the OS, in which case every call is a silent no-op and
/// the capture flow is unaffected (the activity is an ENHANCEMENT, never a gate).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    private init() {}

    #if canImport(ActivityKit)
    private var activity: Activity<DictationActivityAttributes>?
    private var endTask: Task<Void, Never>?

    /// Serializes every ActivityKit mutation (update/end) through ONE ordered
    /// consumer so state pushes apply in the order they were enqueued — detached
    /// `Task { await activity.update(...) }` calls can otherwise complete out of
    /// order, so a stale "listening level" could overwrite a newer "transcribing".
    ///
    /// Each mutation captures the SPECIFIC activity instance it targets, so an
    /// `.end` queued for the old activity always ends THAT one even after `start()`
    /// has already replaced `self.activity` with a fresh instance (end-then-recreate
    /// during the post-publish grace).
    private var mutationTask: Task<Void, Never>?
    private var mutations: AsyncStream<Mutation>.Continuation?

    private enum Mutation {
        case update(Activity<DictationActivityAttributes>, DictationActivityState)
        case end(Activity<DictationActivityAttributes>, DictationActivityState?)
    }

    /// Whether the platform + user settings allow starting a Live Activity.
    private var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// Lazily start the single ordered mutation consumer.
    private func ensureMutationPump() {
        guard mutationTask == nil else { return }
        let stream = AsyncStream<Mutation> { continuation in
            self.mutations = continuation
        }
        mutationTask = Task {
            for await mutation in stream {
                switch mutation {
                case .update(let activity, let state):
                    await activity.update(.init(state: state, staleDate: nil))
                case .end(let activity, let state):
                    if let state {
                        await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
                    } else {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
        }
    }

    private func enqueue(_ mutation: Mutation) {
        ensureMutationPump()
        mutations?.yield(mutation)
    }

    func start(trigger: CaptureTrigger) {
        // A new capture starting while the previous activity is still in its
        // post-publish "Inserted ✓" grace: tear the old one down NOW and recreate,
        // rather than returning and leaving the new capture with no activity.
        endTask?.cancel(); endTask = nil
        if activity != nil { endImmediately() }
        guard activitiesEnabled else { return }
        let initial = DictationActivityState(phase: .starting)
        do {
            activity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: .init(state: initial, staleDate: nil)
            )
        } catch {
            // Requesting can fail (budget, disabled mid-flight). Capture continues.
            activity = nil
        }
    }

    func update(_ state: DictationActivityState) {
        guard let activity else { return }
        enqueue(.update(activity, state))
    }

    /// Start (or reuse) the SESSION Live Activity (WP10b): the armed-window activity
    /// that carries the End Session button. Mirrors `start`, but seeds `.armed` and
    /// leaves teardown to `end()` (the session ends explicitly / on timeout, never on
    /// a per-capture "Inserted" grace).
    func startSession() {
        endTask?.cancel(); endTask = nil
        if activity != nil { endImmediately() }
        guard activitiesEnabled else { return }
        let initial = DictationActivityState(phase: .armed)
        do {
            activity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: .init(state: initial, staleDate: nil)
            )
        } catch {
            activity = nil
        }
    }

    /// Show the terminal success state ("Inserted"), then end the activity after a
    /// short, user-visible beat.
    func finish() {
        guard let activity else { return }
        let done = DictationActivityState(phase: .inserted)
        endTask?.cancel()
        // The terminal update + the delayed end both flow through the ordered
        // mutation pump so they can't race an in-flight level update. Both target
        // THIS activity instance, so a new capture starting during the grace can't
        // have its fresh activity ended by this delayed `.end`.
        enqueue(.update(activity, done))
        // Drop our reference now: the activity is logically finished. A `start()`
        // during the grace will create a new one; the delayed `.end` below still
        // targets the captured `activity`, not `self.activity`.
        self.activity = nil
        endTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.enqueue(.end(activity, done))
        }
    }

    func end() {
        endTask?.cancel(); endTask = nil
        endImmediately()
    }

    /// End the current activity immediately (synchronously drops our reference so a
    /// following `start()` never sees a stale non-nil `activity`; the actual
    /// ActivityKit `end` runs through the ordered pump, targeting the captured
    /// instance).
    private func endImmediately() {
        guard let activity else { return }
        enqueue(.end(activity, nil))
        self.activity = nil
    }
    #else
    func start(trigger: CaptureTrigger) {}
    func startSession() {}
    func update(_ state: DictationActivityState) {}
    func finish() {}
    func end() {}
    #endif
}
