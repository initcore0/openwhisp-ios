// iOS-only: this conformer configures `AVAudioSession` (.playAndRecord/.measurement),
// which is unavailable on macOS. Guarding it keeps the package's macOS `swift test`
// host build (the always-green gate) green; the engines + coordinator + all pure
// logic stay cross-platform and fully testable there.
#if os(iOS)
import Foundation
import AVFoundation
import OpenWhispCore

/// iOS conformer of the upstream `AudioCapture` seam (ARCHITECTURE §6.2, WP3).
///
/// The mac `AudioRecorder` uses CoreAudio device enumeration + AVAudioEngine; on
/// iOS the input device is governed by `AVAudioSession` (there is no CoreAudio
/// `AudioDeviceID` to pin), so this conformer owns:
///
///   - `AVAudioSession` configuration: `.playAndRecord` category with
///     `.measurement` mode and Bluetooth options, so the app can capture while a
///     Live Activity plays a chime and route to AirPods/headsets.
///   - An `AVAudioEngine` input tap that publishes normalized RMS levels (via the
///     ported `AudioLevelMath` curve — the SAME `[0,1]` scale `SilenceAutoStop`
///     is calibrated to) and, in file/chunk modes, writes 16 kHz mono WAVs.
///   - Interruption handling (phone call / Siri) and route-change handling
///     (headset unplug) via `AVAudioSession` notifications, surfaced as
///     `RecorderState.error`/`.stopped`.
///
/// `selectDevice(_:)` is a NO-OP on iOS: the session's `preferredInput` is the
/// only lever and defaults to the sensible built-in/attached mic. The parameter is
/// kept for protocol conformance (a UID means nothing here) — documented rather
/// than silently pretending to route.
///
/// The streaming *transcription* engines (`ParakeetMobileEngine`,
/// `WhisperKitMobileEngine`) own their OWN mic tap (that is how those SDKs are
/// built), so this capture object is used for: file/fixture recording, the level
/// meter feeding the waveform + auto-stop when a non-mic-owning engine is active,
/// and the benchmark harness. It never double-opens the mic alongside a streaming
/// engine — the coordinator picks one owner.
public final class IOSAudioCapture: AudioCapture, @unchecked Sendable {

    // MARK: AudioCapture protocol surface

    public var autoGainEnabled: Bool = false
    public var quietModeEnabled: Bool = false
    public var onStateChanged: ((RecorderState) -> Void)?
    public var onLevelChanged: ((Float) -> Void)?

    // MARK: iOS-specific configuration

    /// The `AVAudioSession` category options. `.allowBluetooth` +
    /// `.allowBluetoothA2DP` so a paired headset can be the input; `.defaultToSpeaker`
    /// keeps any playback (chime/TTS) audible while recording.
    public struct SessionConfig {
        public var category: AVAudioSession.Category = .playAndRecord
        public var mode: AVAudioSession.Mode = .measurement
        public var options: AVAudioSession.CategoryOptions = [
            .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker,
        ]
        public init() {}
    }

    private let sessionConfig: SessionConfig

    public init(sessionConfig: SessionConfig = SessionConfig()) {
        self.sessionConfig = sessionConfig
    }

    // MARK: Internal state (serialized on `stateQueue`)

    private let stateQueue = DispatchQueue(label: "app.openwhisp.ios.audiocapture")
    private var engine: AVAudioEngine?
    /// Writer for the single-file / chunk WAV, when in a file-producing mode.
    private var writer: WAVChunkWriter?
    private var mode: Mode = .idle
    private var observersInstalled = false

    private enum Mode: Equatable {
        case idle
        case singleFile
        case fixedChunk(Double)
        case silenceChunk(SilenceParams)
    }

    private struct SilenceParams: Equatable {
        var silenceDuration: TimeInterval
        var minimumSpeechDuration: TimeInterval
        var maximumSpeechDuration: TimeInterval
        var speechThreshold: Float
    }

    // MARK: - selectDevice (no-op on iOS, documented above)

    public func selectDevice(_ deviceID: String) {
        // iOS routes via AVAudioSession.preferredInput; there is no CoreAudio UID to
        // pin. Intentionally a no-op so callers written against the mac seam compile
        // and behave (system-managed input), rather than silently mis-routing.
    }

    // MARK: - start (single file)

    public func start() {
        beginCapture(mode: .singleFile, onChunk: nil)
    }

    // MARK: - startStreaming (fixed-interval chunks)

    public func startStreaming(chunkDuration: Double, onChunk: @escaping (URL?) -> Void) {
        beginCapture(mode: .fixedChunk(max(0.2, chunkDuration)), onChunk: onChunk)
    }

    // MARK: - startStreamingOnSilence (chunk per detected utterance)

    public func startStreamingOnSilence(
        silenceDuration: TimeInterval,
        minimumSpeechDuration: TimeInterval,
        maximumSpeechDuration: TimeInterval,
        speechThreshold: Float,
        onChunk: @escaping (URL?) -> Void
    ) {
        let params = SilenceParams(
            silenceDuration: silenceDuration,
            minimumSpeechDuration: minimumSpeechDuration,
            maximumSpeechDuration: maximumSpeechDuration,
            speechThreshold: speechThreshold
        )
        beginCapture(mode: .silenceChunk(params), onChunk: onChunk)
    }

    // MARK: - stop

    public func stop(completion: ((URL?) -> Void)?) {
        stateQueue.async { [weak self] in
            guard let self else { completion?(nil); return }
            let finalURL = self.teardownLocked(finishWriter: true)
            self.emitState(.stopped)
            DispatchQueue.main.async { completion?(finalURL) }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture(mode: Mode, onChunk: ((URL?) -> Void)?) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            // Tear down any prior session first (idempotent restart).
            _ = self.teardownLocked(finishWriter: false)

            do {
                try self.activateSession()
            } catch {
                self.emitState(.error("Audio session activation failed: \(error.localizedDescription)"))
                return
            }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                self.emitState(.error("No audio input device available."))
                self.deactivateSession()
                return
            }

            self.mode = mode
            self.chunkSink = onChunk

            // Set up the writer for file-producing modes.
            switch mode {
            case .idle:
                break
            case .singleFile, .fixedChunk, .silenceChunk:
                self.startNewChunkWriter(sampleRate: 16_000)
            }

            self.silenceAccumulatedSpeech = 0
            self.silenceRunStart = nil
            self.chunkStartTime = ProcessInfo.processInfo.systemUptime

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.handleTap(buffer: buffer, inputFormat: format)
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                self.emitState(.error("Audio engine failed to start: \(error.localizedDescription)"))
                _ = self.teardownLocked(finishWriter: false)
                return
            }
            self.engine = engine
            self.installObservers()
            self.emitState(.recording)
        }
    }

    /// A chunk producer for streaming modes; nil for single-file.
    private var chunkSink: ((URL?) -> Void)?
    private var chunkStartTime: TimeInterval = 0
    private var silenceAccumulatedSpeech: TimeInterval = 0
    private var silenceRunStart: TimeInterval?
    private var lastTapTime: TimeInterval?

    private func handleTap(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        // Level: absolute RMS on the AudioLevel curve (drives waveform + VAD).
        let level = Self.level(from: buffer)
        DispatchQueue.main.async { [weak self] in self?.onLevelChanged?(level) }

        stateQueue.async { [weak self] in
            guard let self, self.engine != nil else { return }
            self.writer?.append(buffer)

            let now = ProcessInfo.processInfo.systemUptime
            switch self.mode {
            case .idle, .singleFile:
                break
            case .fixedChunk(let duration):
                if now - self.chunkStartTime >= duration {
                    self.rollChunk(sampleRate: 16_000)
                }
            case .silenceChunk(let p):
                self.advanceSilenceChunking(level: level, now: now, params: p)
            }
        }
    }

    /// Silence-based utterance chunking (a lightweight VAD, mirroring the mac
    /// recorder's `startStreamingOnSilence`).
    private func advanceSilenceChunking(level: Float, now: TimeInterval, params: SilenceParams) {
        let dt = lastTapTime.map { max(0, now - $0) } ?? 0
        lastTapTime = now
        let elapsed = now - chunkStartTime

        if level >= params.speechThreshold {
            silenceAccumulatedSpeech += dt
            silenceRunStart = nil
        } else {
            let runStart = silenceRunStart ?? now
            silenceRunStart = runStart
            let silentFor = now - runStart
            if silenceAccumulatedSpeech >= params.minimumSpeechDuration,
               silentFor >= params.silenceDuration {
                rollChunk(sampleRate: 16_000)
                return
            }
        }
        // Hard cap on utterance length.
        if elapsed >= params.maximumSpeechDuration, silenceAccumulatedSpeech > 0 {
            rollChunk(sampleRate: 16_000)
        }
    }

    /// Finish the current WAV, deliver it, and open a fresh one for the next chunk.
    private func rollChunk(sampleRate: Double) {
        let finished = writer?.finish()
        startNewChunkWriter(sampleRate: sampleRate)
        chunkStartTime = ProcessInfo.processInfo.systemUptime
        silenceAccumulatedSpeech = 0
        silenceRunStart = nil
        let sink = chunkSink
        DispatchQueue.main.async { sink?(finished) }
    }

    private func startNewChunkWriter(sampleRate: Double) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhisp-cap-\(UUID().uuidString).wav")
        writer = try? WAVChunkWriter(url: url, sampleRate: sampleRate, channels: 1)
    }

    /// Tear down engine + tap + session. Returns the finished single-file WAV when
    /// `finishWriter` is set (stop path); nil otherwise (restart path).
    @discardableResult
    private func teardownLocked(finishWriter: Bool) -> URL? {
        removeObservers()
        var finalURL: URL?
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if finishWriter {
            finalURL = writer?.finish()
        }
        writer = nil
        chunkSink = nil
        mode = .idle
        lastTapTime = nil
        deactivateSession()
        return finalURL
    }

    // MARK: - AVAudioSession

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(sessionConfig.category, mode: sessionConfig.mode, options: sessionConfig.options)
        try session.setActive(true, options: [])
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Interruption + route-change handling

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    private func removeObservers() {
        guard observersInstalled else { return }
        observersInstalled = false
        NotificationCenter.default.removeObserver(
            self, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // A begin interruption (phone call / Siri) ends capture: iOS has taken the
        // mic. Surface it as an error so the coordinator aborts the CaptureFlow
        // (mapping to `.interrupted`). We do NOT auto-resume — dictation is
        // short-lived and a mid-utterance resume would splice unrelated audio.
        if type == .began {
            stateQueue.async { [weak self] in
                guard let self, self.engine != nil else { return }
                _ = self.teardownLocked(finishWriter: false)
                self.emitState(.error("Recording was interrupted."))
            }
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Old device unavailable = the input we were capturing from vanished
        // (headset unplugged / Bluetooth dropped). Stop rather than silently
        // continue on a surprise input (the built-in mic pointed elsewhere).
        if reason == .oldDeviceUnavailable {
            stateQueue.async { [weak self] in
                guard let self, self.engine != nil else { return }
                _ = self.teardownLocked(finishWriter: false)
                self.emitState(.error("Audio input route changed."))
            }
        }
    }

    // MARK: - Helpers

    private func emitState(_ state: RecorderState) {
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(state) }
    }

    /// Normalized RMS level (absolute `AudioLevel` curve) for a PCM buffer.
    static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let s = samples[frame]
                sum += s * s
            }
        }
        let rms = (sum / Float(max(1, channelCount * frameCount))).squareRoot()
        return AudioLevelMath.fromRMS(rms)
    }
}
#endif
