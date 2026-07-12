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

    /// Whether the platform + user settings allow starting a Live Activity.
    private var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(trigger: CaptureTrigger) {
        endTask?.cancel(); endTask = nil
        guard activitiesEnabled, activity == nil else { return }
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
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// Show the terminal success state ("Inserted"), then end the activity after a
    /// short, user-visible beat.
    func finish() {
        guard let activity else { return }
        let done = DictationActivityState(phase: .inserted)
        endTask?.cancel()
        endTask = Task {
            await activity.update(.init(state: done, staleDate: nil))
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await activity.end(.init(state: done, staleDate: nil), dismissalPolicy: .immediate)
            self.activity = nil
        }
    }

    func end() {
        endTask?.cancel(); endTask = nil
        guard let activity else { return }
        let current = activity
        self.activity = nil
        Task {
            await current.end(nil, dismissalPolicy: .immediate)
        }
    }
    #else
    func start(trigger: CaptureTrigger) {}
    func update(_ state: DictationActivityState) {}
    func finish() {}
    func end() {}
    #endif
}
