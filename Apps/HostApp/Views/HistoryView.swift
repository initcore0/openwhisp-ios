import SwiftUI
import OpenWhispCore

/// History of finished dictations, backed by the upstream `TranscriptionHistory`
/// types (same JSON shape as the Mac). Tap to view/copy; swipe to delete.
struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore

    var body: some View {
        NavigationStack {
            Group {
                if history.entries.isEmpty {
                    ContentUnavailableView(
                        "No dictations yet",
                        systemImage: "clock",
                        description: Text("Finished dictations from the Dictate tab appear here.")
                    )
                } else {
                    List {
                        ForEach(history.entries) { entry in
                            NavigationLink {
                                HistoryDetailView(entry: entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.text)
                                        .lineLimit(2)
                                    Text(entry.date, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { history.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !history.entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Clear all", role: .destructive) { history.clearAll() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
    }
}

struct HistoryDetailView: View {
    let entry: TranscriptionEntry
    @State private var showCopied = false

    var body: some View {
        ScrollView {
            Text(entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding()
        }
        .navigationTitle(entry.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = entry.text
                    showCopied = true
                } label: { Image(systemName: "doc.on.doc") }
                ShareLink(item: entry.text) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .overlay(alignment: .bottom) {
            if showCopied {
                Text("Copied").font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .task { try? await Task.sleep(nanoseconds: 1_200_000_000); showCopied = false }
            }
        }
    }
}
