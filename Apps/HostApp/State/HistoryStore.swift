import Foundation
import Combine
import OpenWhispCore

/// Observable wrapper over the upstream `TranscriptionHistoryStore` — the SAME
/// `history.json` shape + Application Support location as the Mac app, so a future
/// sync can move entries between devices without a schema translation (ARCHITECTURE
/// §3: `TranscriptionHistory` types reused as-is, "same schema as Mac → syncable").
///
/// On iOS, Application Support lives inside the app's own container, so this is the
/// app container the requirement asks for.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [TranscriptionEntry]

    init() {
        self.entries = TranscriptionHistoryStore.load()
    }

    /// Append a finished dictation (newest first) and persist, bounded to the
    /// upstream retention cap. Updates the in-memory `entries` for the observing UI.
    func append(text: String, rawText: String?) {
        guard let entry = Self.makeEntry(text: text, rawText: rawText) else { return }
        var updated = [entry] + entries
        if updated.count > TranscriptionHistoryStore.maxEntries {
            updated.removeLast(updated.count - TranscriptionHistoryStore.maxEntries)
        }
        entries = updated
        TranscriptionHistoryStore.save(updated)
    }

    /// Persist a finished dictation to the SAME `history.json` WITHOUT needing a
    /// live `HistoryStore` instance — used by the hero/App-Intent capture path
    /// (`IntentCaptureController`), which runs in a context (possibly backgrounded)
    /// where the app's `@StateObject HistoryStore` may not exist yet. Loads the
    /// current entries fresh from disk so it never clobbers concurrent writes, then
    /// prepends + caps + saves. This gives the hero path history PARITY with the
    /// composer + sheet paths (all three land in the one store).
    @discardableResult
    static func appendToStore(text: String, rawText: String?) -> Bool {
        guard let entry = makeEntry(text: text, rawText: rawText) else { return false }
        var updated = [entry] + TranscriptionHistoryStore.load()
        if updated.count > TranscriptionHistoryStore.maxEntries {
            updated.removeLast(updated.count - TranscriptionHistoryStore.maxEntries)
        }
        TranscriptionHistoryStore.save(updated)
        return true
    }

    private static func makeEntry(text: String, rawText: String?) -> TranscriptionEntry? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TranscriptionEntry(
            text: text,
            date: Date(),
            appBundleID: Bundle.main.bundleIdentifier,
            appName: "OpenWhisp",
            rawText: rawText
        )
    }

    func delete(_ entry: TranscriptionEntry) {
        entries.removeAll { $0.id == entry.id }
        TranscriptionHistoryStore.save(entries)
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        TranscriptionHistoryStore.save(entries)
    }

    func clearAll() {
        entries = []
        TranscriptionHistoryStore.save([])
    }
}
