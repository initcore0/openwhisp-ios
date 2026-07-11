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
    /// upstream retention cap.
    func append(text: String, rawText: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let entry = TranscriptionEntry(
            text: text,
            date: Date(),
            appBundleID: Bundle.main.bundleIdentifier,
            appName: "OpenWhisp",
            rawText: rawText
        )
        var updated = [entry] + entries
        if updated.count > TranscriptionHistoryStore.maxEntries {
            updated.removeLast(updated.count - TranscriptionHistoryStore.maxEntries)
        }
        entries = updated
        TranscriptionHistoryStore.save(updated)
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
