import Foundation

// MARK: - CaptureKit (placeholder — WP3)
//
// The host-side, OS-bound half of capture. This target is a placeholder in WP1
// (the scaffold): it holds only this doc comment so the target compiles and the
// module boundary exists. No feature code lands until WP3.
//
// When WP3 arrives, CaptureKit will own (all conforming to seams declared in
// MobileCore and, later, upstream OpenWhispCore):
//
//   - `IOSAudioCapture: AudioCapture`         — AVAudioSession (.playAndRecord,
//                                                .measurement) + AVAudioEngine tap,
//                                                route/interruption handling, RMS/VAD.
//   - `WhisperKitMobileEngine`, `ParakeetMobileEngine: StreamingTranscriptionEngine`
//                                              — the on-device engines (D5).
//   - `CaptureCoordinator: CaptureCoordinating` — @MainActor driver that executes
//                                                `CaptureFlow` effects, wiring
//                                                capture → engine → SilenceAutoStop
//                                                → TranscriptCleaner → handoff.
//   - `ModelProvisioning` conformer            — model download/staging.
//   - App Intents glue (`StartDictationIntent: AudioRecordingIntent`, etc.).
//
// CaptureKit deliberately depends only on MobileCore for now; the upstream
// OpenWhispCore dependency is added with the engine work (not WP1).

/// Marker so the module is non-empty and its presence is greppable. Removed when
/// real types land in WP3.
enum CaptureKitPlaceholder {}
