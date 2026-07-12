import Foundation
import Combine
import MobileCore

/// App-wide router for presenting the dictation sheet (ARCHITECTURE §5.2). The
/// floor flow enters when the app is opened on `openwhisp://dictate`; the composer
/// affordance and the App Intent's foreground-fallback also route through here so
/// there is ONE place that decides "show the sheet". Deep-link parsing is the pure,
/// tested `DeepLink.parse`; this object only holds the resulting presentation state.
@MainActor
final class DictationRouter: ObservableObject {
    /// The trigger for the sheet to present, or nil when no sheet is up. Binding
    /// this to `.sheet(item:)` makes presentation a pure function of routing.
    @Published var pending: PendingSheet?

    struct PendingSheet: Identifiable, Equatable {
        let id = UUID()
        let trigger: CaptureTrigger
    }

    /// Handle an incoming URL. Only `openwhisp://dictate` presents the sheet; any
    /// other route is ignored (logged by the caller). Returns whether it routed.
    @discardableResult
    func handle(url: URL) -> Bool {
        switch DeepLink.parse(url) {
        case .dictate:
            present(trigger: .keyboardHandoff)
            return true
        case .unknown:
            return false
        }
    }

    /// Present the sheet for a given trigger (used by the composer affordance and
    /// the App Intent foreground fallback).
    func present(trigger: CaptureTrigger) {
        pending = PendingSheet(trigger: trigger)
    }
}
