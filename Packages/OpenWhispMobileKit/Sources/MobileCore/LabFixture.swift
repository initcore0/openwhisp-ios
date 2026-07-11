import Foundation

// MARK: - Engine Lab fixtures (WP3)
//
// The Engine Lab runs bundled WAV fixtures through engines and scores the result
// against the fixture's known reference transcript. The list of fixtures + their
// languages is pure metadata (which fixture is which language, what its reference
// text is), so it lives here and is unit-tested. The host app resolves the actual
// WAV/txt file URLs from the bundle (Debug-only bundling; see project.yml + docs).

/// A bundled benchmark fixture: a WAV whose spoken content is known, paired with a
/// reference transcript to score against. `language` is the fixture's actual spoken
/// language so the Lab can preselect the right language hint (and the right Apple
/// baseline locale).
public struct LabFixture: Equatable, Sendable, Identifiable {
    public var id: String { name }
    /// Base filename (no extension), matching both `<name>.wav` and `<name>.txt`.
    public let name: String
    /// Human display title.
    public let title: String
    /// BCP-47-ish language of the spoken content ("en", "ru", "fr", "de", "es"),
    /// or "" for the silence fixture.
    public let language: String
    /// Whether this fixture is silence (empty reference) — the Lab shows it as a
    /// "should produce nothing" negative test.
    public let isSilence: Bool

    public init(name: String, title: String, language: String, isSilence: Bool = false) {
        self.name = name
        self.title = title
        self.language = language
        self.isSilence = isSilence
    }
}

/// The catalog of fixtures shipped with the app's Debug builds. Mirrors
/// `fixtures/audio/*.wav` (5 English/neutral + 4 multilingual). The multilingual
/// ones are what prove Goal #1 against Apple's baseline.
public enum LabFixtureCatalog {
    public static let all: [LabFixture] = [
        // English / neutral
        LabFixture(name: "plain_speech", title: "Plain speech (pangram)", language: "en"),
        LabFixture(name: "numbers_dates", title: "Numbers & dates", language: "en"),
        LabFixture(name: "two_utterances", title: "Two utterances", language: "en"),
        LabFixture(name: "speech_then_silence", title: "Speech then silence", language: "en"),
        LabFixture(name: "silence", title: "Silence (negative test)", language: "", isSilence: true),
        // Multilingual — the headline
        LabFixture(name: "french_greeting", title: "French greeting", language: "fr"),
        LabFixture(name: "german_greeting", title: "German greeting", language: "de"),
        LabFixture(name: "spanish_greeting", title: "Spanish greeting", language: "es"),
        LabFixture(name: "russian_greeting", title: "Russian greeting", language: "ru"),
    ]

    public static func fixture(named name: String) -> LabFixture? {
        all.first { $0.name == name }
    }

    /// Just the multilingual (non-English, non-silence) fixtures — the set that
    /// exposes Apple's on-device coverage gaps.
    public static var multilingual: [LabFixture] {
        all.filter { !$0.isSilence && $0.language != "en" }
    }

    /// Map a fixture language to the BCP-47 locale the Apple baseline needs
    /// (`SFSpeechRecognizer` is single-locale, no "auto"). "" / "en" → "en-US".
    public static func appleLocale(for language: String) -> String {
        switch language {
        case "ru": return "ru-RU"
        case "fr": return "fr-FR"
        case "de": return "de-DE"
        case "es": return "es-ES"
        case "en", "": return "en-US"
        default: return language.contains("-") ? language : "\(language)-\(language.uppercased())"
        }
    }
}
