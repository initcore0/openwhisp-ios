import Foundation
import Combine
import MobileCore
import CaptureKit
import OpenWhispCore

/// Drives the Engine Lab screen (WP3, product Goal #1). Resolves bundled fixtures,
/// runs them through a chosen engine (or the Apple baseline) via `LabRunner`, holds
/// the latest single-run and compare-mode results, and records every run to the
/// persisted `LabRunStore`.
///
/// The scoring/verdict logic is pure `MobileCore` (`WordErrorRate`, `LabVerdict`);
/// this view model is the OS-bound glue (bundle URLs, `LabRunner`, async runs).
@MainActor
final class EngineLabViewModel: ObservableObject {

    /// A fixture the app actually shipped (present in the bundle). Debug builds bundle
    /// `fixtures/audio/`; a release build may not, so we only surface what's present.
    struct BundledFixture: Identifiable {
        let fixture: LabFixture
        let wavURL: URL
        let reference: String
        var id: String { fixture.id }
    }

    @Published private(set) var fixtures: [BundledFixture] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status: String = ""
    /// The most recent single run (for the transcript/diff/metrics panel).
    @Published private(set) var lastRun: LabRun?
    @Published private(set) var lastDiff: WERResult?
    /// Compare-mode results: OpenWhisp run, Apple baseline run, and the verdict.
    @Published private(set) var compareOpenWhisp: LabRun?
    @Published private(set) var compareApple: LabRun?
    @Published private(set) var compareVerdict: LabVerdict?

    private let settings: AppSettings
    private let store: LabRunStore
    private let runner = LabRunner()

    init(settings: AppSettings, store: LabRunStore) {
        self.settings = settings
        self.store = store
        loadFixtures()
    }

    // MARK: - Fixture resolution

    /// Resolve the fixtures actually present in the bundle. Fixtures are bundled from
    /// `fixtures/audio/` (Debug config; see project.yml). We look them up as bundle
    /// resources by name; whatever the bundle carries is what the Lab lists.
    private func loadFixtures() {
        var out: [BundledFixture] = []
        for fx in LabFixtureCatalog.all {
            guard let wav = Self.resource(named: fx.name, ext: "wav") else { continue }
            let reference = Self.resource(named: fx.name, ext: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            out.append(BundledFixture(fixture: fx, wavURL: wav, reference: reference))
        }
        fixtures = out
    }

    private static func resource(named name: String, ext: String) -> URL? {
        // The fixtures are bundled as a folder reference (project.yml). XcodeGen
        // preserves the source leaf dir name (`fixtures/audio` → `audio/` in the
        // bundle), so look under `audio/` first, then `Fixtures/` (in case the
        // bundling layout changes), then a flat lookup. Any layout resolves.
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "audio")
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    var fixturesAvailable: Bool { !fixtures.isEmpty }

    // MARK: - The current engine selection (from settings)

    private var currentSelection: LabEngineSelection {
        switch settings.engineFamily {
        case .parakeet: return .parakeet(variantID: settings.parakeetVariant)
        case .whisperKit: return .whisperKit(modelID: settings.whisperModel)
        }
    }

    // MARK: - Single run

    /// Run one fixture through the currently-selected OpenWhisp engine.
    func run(_ bundled: BundledFixture) async {
        await run(bundled, selection: currentSelection, langOverride: nil, isCompare: false)
    }

    /// Run one fixture through an explicit engine selection (used by the Lab's
    /// engine override picker).
    func run(_ bundled: BundledFixture, selection: LabEngineSelection) async {
        await run(bundled, selection: selection, langOverride: nil, isCompare: false)
    }

    private func run(
        _ bundled: BundledFixture,
        selection: LabEngineSelection,
        langOverride: String?,
        isCompare: Bool
    ) async {
        guard !isRunning else { return }
        isRunning = true
        status = "Running \(selection.displayName) on \(bundled.fixture.title)…"
        defer { isRunning = false; status = "" }

        // For a fixed-language fixture, default the hint to that language unless the
        // user picked one; Apple baseline needs a concrete locale.
        let language = langOverride ?? labLanguage(for: bundled.fixture, selection: selection)

        let run = await runner.run(
            fixture: bundled.fixture,
            wavURL: bundled.wavURL,
            reference: bundled.reference,
            selection: selection,
            language: language
        )
        store.record(run)
        if !isCompare {
            lastRun = run
            lastDiff = bundled.reference.isEmpty && !bundled.fixture.isSilence
                ? nil
                : WordErrorRate.score(reference: bundled.reference, hypothesis: run.hypothesis)
            // A fresh single run clears any stale compare panel.
            compareOpenWhisp = nil
            compareApple = nil
            compareVerdict = nil
        }
    }

    // MARK: - Compare mode (vs Apple baseline)

    /// Run the SAME fixture through the selected OpenWhisp engine AND the Apple
    /// on-device baseline, then compute the verdict. This is the product's Goal-#1
    /// claim rendered as a single sentence.
    func compare(_ bundled: BundledFixture) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; status = "" }

        let language = labLanguage(for: bundled.fixture, selection: currentSelection)
        let appleLocale = LabFixtureCatalog.appleLocale(for: bundled.fixture.language)

        status = "Running OpenWhisp on \(bundled.fixture.title)…"
        let ow = await runner.run(
            fixture: bundled.fixture, wavURL: bundled.wavURL, reference: bundled.reference,
            selection: currentSelection, language: language
        )
        store.record(ow)

        status = "Running Apple baseline (\(appleLocale))…"
        let apple = await runner.run(
            fixture: bundled.fixture, wavURL: bundled.wavURL, reference: bundled.reference,
            selection: .appleBaseline(locale: appleLocale),
            language: LabFixtureCatalog.appleLocale(for: bundled.fixture.language)
        )
        store.record(apple)

        compareOpenWhisp = ow
        compareApple = apple
        // Apple WER is nil when its run errored (no on-device model for the locale).
        let appleWER = apple.error == nil ? apple.wer : nil
        compareVerdict = LabVerdict.decide(openWhispWER: ow.wer, appleWER: appleWER)
        lastRun = ow
        lastDiff = bundled.reference.isEmpty && !bundled.fixture.isSilence
            ? nil
            : WordErrorRate.score(reference: bundled.reference, hypothesis: ow.hypothesis)
    }

    /// Language hint for a Lab run: fixed-language fixtures pin their language; the
    /// silence/English ones follow the user's hint. Apple runs always need a locale.
    private func labLanguage(for fixture: LabFixture, selection: LabEngineSelection) -> String {
        if case .appleBaseline = selection {
            return LabFixtureCatalog.appleLocale(for: fixture.language)
        }
        if fixture.language.isEmpty { return settings.languageHint }
        if fixture.language == "en" { return settings.languageHint == "auto" ? "en" : settings.languageHint }
        return fixture.language
    }
}
