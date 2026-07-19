import Foundation
import Combine
import MobileCore
import CaptureKit
import OpenWhispCore

/// The engine family the user has chosen for dictation.
enum EngineFamily: String, CaseIterable, Codable, Identifiable {
    case parakeet
    case whisperKit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .parakeet: return "Parakeet (recommended)"
        case .whisperKit: return "WhisperKit"
        }
    }
    var blurb: String {
        switch self {
        case .parakeet: return "On-device NVIDIA Parakeet. Fast, punctuated, multilingual. The default."
        case .whisperKit: return "OpenAI Whisper on CoreML. The ~100-language long tail."
        }
    }
}

/// User-facing settings, persisted to `UserDefaults`. Thin — the decision-like
/// resolution (which model id for a family, recommended default) delegates to the
/// upstream catalogs + `ModelProvisioning`, and the pieces that matter for the
/// pipeline (cleaner config, language) are derived here for the composer to consume.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    private enum Key {
        static let onboarded = "ow.onboarded"
        static let engineFamily = "ow.engineFamily"
        static let parakeetVariant = "ow.parakeetVariant"
        static let whisperModel = "ow.whisperModel"
        static let languageHint = "ow.languageHint"
        static let sessionIdleTimeout = "ow.sessionIdleTimeout"
    }

    @Published var didOnboard: Bool {
        didSet { defaults.set(didOnboard, forKey: Key.onboarded) }
    }
    @Published var engineFamily: EngineFamily {
        didSet { defaults.set(engineFamily.rawValue, forKey: Key.engineFamily) }
    }
    /// Parakeet variant id from `ParakeetCatalog` (e.g. "nemotron-multilingual-1120ms").
    @Published var parakeetVariant: String {
        didSet { defaults.set(parakeetVariant, forKey: Key.parakeetVariant) }
    }
    /// WhisperKit model id (e.g. "openai_whisper-small").
    @Published var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Key.whisperModel) }
    }
    /// Language hint: "auto" or a code like "en"/"ru".
    @Published var languageHint: String {
        didSet { defaults.set(languageHint, forKey: Key.languageHint) }
    }
    /// Dictation-session idle timeout (WP10, D11): how long an armed-but-idle session
    /// survives before it auto-ends. Default `.fiveMinutes` — a short default owns the
    /// mic-privacy story (the orange indicator is on for the whole armed window).
    @Published var sessionIdleTimeout: DictationSessionConfig.IdleTimeout {
        didSet { defaults.set(sessionIdleTimeout.rawValue, forKey: Key.sessionIdleTimeout) }
    }

    /// The persisted session config the arming flow uses.
    var sessionConfig: DictationSessionConfig {
        DictationSessionConfig(idleTimeout: sessionIdleTimeout)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Deterministic UI-test entry: `-uitest-skip-onboarding` lands straight on
        // the main TabView so the XCUITest smoke never depends on the onboarding
        // flow (or any model download). Never set outside tests.
        let skipOnboarding = ProcessInfo.processInfo.arguments.contains("-uitest-skip-onboarding")
        self.didOnboard = skipOnboarding || defaults.bool(forKey: Key.onboarded)
        self.engineFamily = EngineFamily(rawValue: defaults.string(forKey: Key.engineFamily) ?? "")
            ?? .parakeet
        self.parakeetVariant = defaults.string(forKey: Key.parakeetVariant)
            ?? ParakeetCatalog.defaultVariantID
        self.whisperModel = defaults.string(forKey: Key.whisperModel)
            ?? "openai_whisper-small"
        self.languageHint = defaults.string(forKey: Key.languageHint) ?? "auto"
        self.sessionIdleTimeout = defaults.string(forKey: Key.sessionIdleTimeout)
            .flatMap(DictationSessionConfig.IdleTimeout.init(rawValue:)) ?? .fiveMinutes
    }

    /// The model id currently selected for the active engine family.
    var activeModelID: ModelID {
        switch engineFamily {
        case .parakeet: return ModelID(parakeetVariant)
        case .whisperKit: return ModelID(whisperModel)
        }
    }

    /// The `EngineCache` selection for the active engine — the one key every
    /// capture surface uses so they all share the same warm engine instance.
    var engineSelection: EngineSelection {
        switch engineFamily {
        case .parakeet: return .parakeet(variantID: parakeetVariant)
        case .whisperKit: return .whisperKit(model: whisperModel)
        }
    }

    /// The available language-hint choices for the picker. "auto" plus the fixture
    /// languages the product cares about.
    static let languageChoices: [(code: String, label: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("ru", "Russian"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
    ]

    /// A conservative `TranscriptCleaner.Config` for the composer. Mirrors the mac
    /// defaults: smart formatting + filler removal + spoken punctuation on, number
    /// normalization off (safe cross-language). Language follows the hint.
    func cleanerConfig() -> TranscriptCleaner.Config {
        TranscriptCleaner.Config(
            language: languageHint == "auto" ? "en" : languageHint,
            customVocabularyEnabled: false,
            substitutions: [],
            smartFormattingEnabled: true,
            fillerRemovalEnabled: true,
            spokenPunctuationEnabled: true
        )
    }

    /// Recommended defaults for onboarding, using the provisioning heuristic keyed
    /// to the device's RAM class.
    func applyRecommendedDefaults(provisioning: ModelProvisioning, deviceClass: DeviceClass) {
        let rec = provisioning.recommendedDefault(for: deviceClass)
        // A recommended id is a Parakeet variant when the catalog knows it (or it
        // uses the Parakeet/Nemotron naming). Otherwise treat it as a WhisperKit id.
        let isParakeet = ParakeetCatalog.variants.contains { $0.id == rec.rawValue }
            || rec.rawValue.hasPrefix("parakeet-")
            || rec.rawValue.hasPrefix("nemotron-")
        if isParakeet {
            engineFamily = .parakeet
            parakeetVariant = ParakeetCatalog.normalize(rec.rawValue)
        } else {
            engineFamily = .whisperKit
            whisperModel = rec.rawValue
        }
    }
}
