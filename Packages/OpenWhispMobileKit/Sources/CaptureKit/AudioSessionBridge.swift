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
public final class IOSAudioSessionController: AudioSessionControlling {
    private let config: IOSAudioCapture.SessionConfig
    public init(config: IOSAudioCapture.SessionConfig = IOSAudioCapture.SessionConfig()) {
        self.config = config
    }
    public func activate() throws {
        try AudioSessionBridge.activate(config: config)
    }
    public func deactivate() {
        AudioSessionBridge.deactivate()
    }
}
#endif
