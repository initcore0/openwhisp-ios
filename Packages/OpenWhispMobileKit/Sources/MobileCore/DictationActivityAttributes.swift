import Foundation

// Guarded on `os(iOS)`, NOT `canImport(ActivityKit)`: ActivityKit is importable on
// the macOS `swift test` host, but its `ActivityAttributes` protocol is marked
// UNAVAILABLE there, so conforming to it fails to compile under `swift test`. Live
// Activities are an iOS-only surface, so gate on the platform.
#if os(iOS)
import ActivityKit

// MARK: - Live Activity attributes (iOS-only)
//
// The `ActivityAttributes` type must be SHARED between the host app (which
// starts/updates/ends the activity) and the widgets extension (which renders it),
// so it lives in MobileCore — the one module both import. The dynamic content is
// the pure `DictationActivityState` defined alongside; this file only adds the
// ActivityKit conformance, compiled only where ActivityKit exists (iOS).
//
// The static attributes are empty: everything the presentation needs is dynamic
// (phase + level), and there is nothing fixed per-activity worth carrying.

/// The Live Activity for a dictation capture. `ContentState` is the pure
/// `DictationActivityState` (phase + level), so the widget renders straight from a
/// `swift test`-covered value type.
public struct DictationActivityAttributes: ActivityAttributes {
    public typealias ContentState = DictationActivityState

    public init() {}
}
#endif
