import Foundation
import Combine
import MobileCore

/// Observable, persisted store of Engine Lab runs. The retention rule + JSON codec
/// are pure `MobileCore.LabRunLog` (tested on the gate); this wrapper is the thin
/// file I/O around them. Persisted as `lab-runs.json` in Application Support so the
/// evidence survives relaunch and can be exported.
@MainActor
final class LabRunStore: ObservableObject {
    @Published private(set) var runs: [LabRun]

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("OpenWhisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lab-runs.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? LabRunLog.decode(data) {
            self.runs = decoded
        } else {
            self.runs = []
        }
    }

    func record(_ run: LabRun) {
        runs = LabRunLog.appending(run, to: runs)
        persist()
    }

    func clear() {
        runs = []
        persist()
    }

    /// The runs encoded as pretty JSON for export/share.
    func exportData() -> Data? {
        try? LabRunLog.encode(runs)
    }

    private func persist() {
        guard let data = try? LabRunLog.encode(runs) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
