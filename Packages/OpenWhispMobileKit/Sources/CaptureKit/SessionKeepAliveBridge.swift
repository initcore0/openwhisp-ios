#if os(iOS)
import Foundation
import AVFoundation
import MobileCore

// MARK: - iOS keep-alive audio + timers for SessionHolder (WP10b)
//
// The OS-bound conformers of the `SessionHolder` seams. Kept in an iOS-only file so
// the driver + its tests stay platform-neutral on the macOS `swift test` host.

/// Production `SessionAudioControlling`: activates the shared `AVAudioSession`
/// (`.playAndRecord` / `.measurement`, matching `IOSAudioCapture.SessionConfig`) and
/// holds a MINIMAL keep-alive engine tap so iOS keeps the process running under the
/// `audio` background mode across the whole armed window (ARCHITECTURE §6.8 driver
/// notes, risk R10a). The tap is a zero-work input-node tap: it does nothing with the
/// buffers — its only job is to keep a live audio graph so the background mode holds.
///
/// This is DISTINCT from the per-capture `IOSAudioSessionController`: that one is
/// activated/deactivated around a single capture; this one spans the session. During
/// a capture the streaming engine installs its OWN tap on the same input node; the
/// keep-alive tap is removed while capturing and reinstalled when capture ends, so
/// the two never fight over the input node.
public final class IOSSessionKeepAlive: SessionAudioControlling {

    private let config: IOSAudioCapture.SessionConfig
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    public var onInterruption: (() -> Void)?

    public init(config: IOSAudioCapture.SessionConfig = IOSAudioCapture.SessionConfig()) {
        self.config = config
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func activateKeepAlive() throws {
        try AudioSessionBridge.activate(config: config)
        installKeepAliveTap()
    }

    public func deactivateKeepAlive() {
        removeKeepAliveTap()
        engine.stop()
        AudioSessionBridge.deactivate()
    }

    public func suspendKeepAliveTap() {
        // Hand the input node to the capture engine: drop our tap and pause the graph
        // (the shared AVAudioSession stays active, so the mic — and the background
        // mode — hold across the capture).
        removeKeepAliveTap()
        engine.pause()
    }

    public func resumeKeepAliveTap() {
        // Capture ended but the session is still armed: reinstall the silent tap so
        // the idle window keeps a live graph for the `audio` background mode.
        installKeepAliveTap()
    }

    /// Install the silent keep-alive tap and start the engine. Idempotent.
    private func installKeepAliveTap() {
        guard !tapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A tiny buffer with a no-op block: we never read the audio here (the
        // streaming engine owns capture) — this just keeps a live graph so the
        // `audio` background mode holds while merely ARMED (not capturing).
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
        tapInstalled = true
        engine.prepare()
        try? engine.start()
    }

    private func removeKeepAliveTap() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // A begin interruption (phone call / Siri) that ends our session. We do NOT
        // auto-resume — the session ends honestly, and the user re-arms with one hop.
        if type == .began {
            onInterruption?()
        }
    }
}

/// Production `SessionTimerScheduling` built on `DispatchSourceTimer`s on the main
/// queue (the driver is `@MainActor`). One-shot idle check + repeating heartbeat +
/// repeating mailbox poll, each independently (re)schedulable and cancelable.
public final class DispatchSessionTimers: SessionTimerScheduling {

    private var idleTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var pollTimer: DispatchSourceTimer?

    public init() {}

    public func scheduleIdleCheck(at date: Date, onFire: @escaping @Sendable () -> Void) {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay = max(0, date.timeIntervalSinceNow)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler(handler: onFire)
        idleTimer = timer
        timer.resume()
    }

    public func cancelIdleCheck() {
        idleTimer?.cancel()
        idleTimer = nil
    }

    public func startHeartbeat(interval: TimeInterval, onTick: @escaping @Sendable () -> Void) {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: onTick)
        heartbeatTimer = timer
        timer.resume()
    }

    public func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    public func startMailboxPoll(interval: TimeInterval, onTick: @escaping @Sendable () -> Void) {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: onTick)
        pollTimer = timer
        timer.resume()
    }

    public func stopMailboxPoll() {
        pollTimer?.cancel()
        pollTimer = nil
    }
}

// MARK: - Session command Darwin listener

/// Host-side Darwin listener for the keyboard's command ping
/// (`SessionDarwinNames.command`). A payload-free wake-up: on fire the driver drains
/// the mailbox (the 250 ms poll is the reliability floor; this makes the common case
/// instant). Mirrors `DarwinHandoffNotifier`'s CFNotificationCenter pattern.
public final class SessionCommandDarwinListener: @unchecked Sendable {

    public var onCommand: (() -> Void)?

    public init() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<SessionCommandDarwinListener>.fromOpaque(observer).takeUnretainedValue()
                me.onCommand?()
            },
            SessionDarwinNames.command as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }
}

/// Posts the host → keyboard pings (`SessionDarwinNames.status` / `.partial`). The
/// driver calls these on status/partial writes so a frontmost keyboard wakes
/// immediately; its 250 ms poll is the floor.
public enum SessionDarwinPoster {
    public static func postStatus() { post(SessionDarwinNames.status) }
    public static func postPartial() { post(SessionDarwinNames.partial) }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }
}
#endif
