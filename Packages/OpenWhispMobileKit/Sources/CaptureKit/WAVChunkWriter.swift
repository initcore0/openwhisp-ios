import Foundation
import AVFoundation

/// Writes captured PCM buffers to a 16 kHz mono 16-bit WAV file, resampling from
/// the input tap's native format on the fly.
///
/// The file/fixture transcription engines (WhisperKit file, Parakeet TDT v3) all
/// take a WAV path; FluidAudio resamples internally, but WhisperKit's file path is
/// happiest with 16 kHz mono, and a canonical format keeps fixtures deterministic.
/// Used only by `IOSAudioCapture`'s file/chunk modes — the streaming engines own
/// their own mic and never touch this.
final class WAVChunkWriter {
    private let file: AVAudioFile
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    let url: URL
    private var wroteAnyFrames = false

    init(url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        self.url = url
        // 16-bit signed integer PCM WAV, the canonical transcription input format.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        self.file = try AVAudioFile(forWriting: url, settings: settings)
        // The processing format the converter must target (float, matches AVAudioFile).
        guard let out = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: channels
        ) else {
            throw WAVWriterError.formatUnavailable
        }
        self.outputFormat = out
    }

    /// Append a buffer, resampling to the file's format when the input differs.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let inFormat = buffer.format
        if inFormat.sampleRate == outputFormat.sampleRate,
           inFormat.channelCount == outputFormat.channelCount,
           inFormat.commonFormat == outputFormat.commonFormat {
            writeConverted(buffer)
            return
        }
        // Build/reuse a converter for this input format.
        if converter == nil || converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: outputFormat)
            converterInputFormat = inFormat
        }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: capacity
        ) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || error != nil { return }
        if outBuffer.frameLength > 0 { writeConverted(outBuffer) }
    }

    private func writeConverted(_ buffer: AVAudioPCMBuffer) {
        do {
            try file.write(from: buffer)
            wroteAnyFrames = true
        } catch {
            NSLog("[WAVChunkWriter] write failed: %@", error.localizedDescription)
        }
    }

    /// Close the file and return its URL (nil if nothing was ever written, so an
    /// empty chunk doesn't reach a transcriber as a zero-length WAV).
    func finish() -> URL? {
        // AVAudioFile flushes + closes on deinit; dropping our reference is enough,
        // but we keep the file alive until here so `wroteAnyFrames` is accurate.
        guard wroteAnyFrames else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    enum WAVWriterError: Error { case formatUnavailable }
}
