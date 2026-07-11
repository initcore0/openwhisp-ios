#if os(iOS)
import Foundation
import AVFoundation

/// The single point that touches `AVAudioSession` category/activation, shared by
/// `IOSAudioSessionController` (for the coordinator) and available to the capture
/// object. Isolated here so the coordinator's own file stays platform-neutral (it
/// depends only on the `AudioSessionControlling` protocol, which lets the tests run
/// on the macOS `swift test` host where `AVAudioSession` is unavailable).
enum AudioSessionBridge {
    static func activate(config: IOSAudioCapture.SessionConfig) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(config.category, mode: config.mode, options: config.options)
        try session.setActive(true, options: [])
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Production `AudioSessionControlling` backed by `AVAudioSession`. Kept tiny and
/// separate from `IOSAudioCapture` so the streaming engine (which owns its own tap)
/// and the coordinator share ONE session configuration point. iOS-only (macOS has
/// no `AVAudioSession`); the coordinator itself is cross-platform via the protocol.
///
/// This is ALSO the single place session interruptions/route-losses reach the
/// coordinator: the streaming engines own the mic but observe no `AVAudioSession`
/// notifications, so without this the flow would stick in `.listening` with a dead
/// tap after a phone call / Siri / headset unplug. It installs the notification
/// observers and fires `onInterruption`, which the coordinator maps to `.interrupted`.
public final class IOSAudioSessionController: AudioSessionControlling {
    private let config: IOSAudioCapture.SessionConfig
    public var onInterruption: (() -> Void)?

    public init(config: IOSAudioCapture.SessionConfig = IOSAudioCapture.SessionConfig()) {
        self.config = config
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func activate() throws {
        try AudioSessionBridge.activate(config: config)
    }
    public func deactivate() {
        AudioSessionBridge.deactivate()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // A begin interruption (phone call / Siri) has taken the mic. Surface it so
        // the coordinator aborts the flow. We do NOT auto-resume — dictation is
        // short-lived, and splicing post-interruption audio into the same utterance
        // is worse than a clean stop.
        if type == .began {
            onInterruption?()
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Old device unavailable = the input we were capturing from vanished
        // (headset unplugged / Bluetooth dropped). Treat the loss of input as an
        // interruption; only fire when the new route actually has NO input, so a
        // benign output-only route change (e.g. speaker → headphones) is ignored.
        guard reason == .oldDeviceUnavailable else { return }
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        if inputs.isEmpty {
            onInterruption?()
        }
    }
}
#endif
