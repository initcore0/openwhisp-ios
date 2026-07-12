import Foundation
import OpenWhispCore
import OpenWhispBridgeKit
import SyncCore

/// Orchestrates one foreground sync over a paired ``BridgeSession`` (ARCHITECTURE
/// §6.5): manifest exchange → pure plan → pull/push → apply to LOCAL stores →
/// ``SyncReport``. No daemon; the app calls `run` on foreground / Sync Now.
///
/// The engine is transport-agnostic (it takes any `BridgeSession`) and store-
/// agnostic (any ``SyncLocalStore``), so the loopback test drives it against an
/// in-process fake server + in-memory store, and the app drives it against the
/// real TLS session + JSON stores — the same code path.
public final class SyncEngine {
    private let store: SyncLocalStore
    private let planner = SyncPlanner()

    public init(store: SyncLocalStore) {
        self.store = store
    }

    public enum EngineError: Error {
        case manifest(String)
        case pull(String)
        case push(String)
    }

    /// Run a full sync. Assumes `session` is already connected + handshaked (the
    /// transport does that in `connect`). Returns what merged in each direction.
    @discardableResult
    public func run(with session: any BridgeSession, now: () -> Date = Date.init) throws -> SyncReport {
        let started = now()

        // 1. Remote manifest.
        let remoteWire: BridgeWire.SyncManifestResult
        do {
            remoteWire = try session.call(
                method: BridgeWire.Method.syncManifest.rawValue,
                params: BridgeWire.NoParams(),
                resultType: BridgeWire.SyncManifestResult.self)
        } catch { throw EngineError.manifest("\(error)") }
        let remote = Self.manifest(from: remoteWire)

        // 2. Local manifest + pure plan.
        let localState = store.snapshot()
        let local = SyncManifestBuilder.manifest(for: localState)
        let plan = planner.plan(local: local, remote: remote)

        var pulled = SyncReport.SectionCounts()
        var pushed = SyncReport.SectionCounts()

        // 3. Pull: fetch the sections the plan asked for and merge into local.
        if !plan.pull.isEmpty {
            let want = plan.pull.compactMap { BridgeWire.SyncSection(rawValue: $0.rawValue) }
            let cursor = plan.historyCursor.map(BridgeWire.iso8601String(from:))
            let params = BridgeWire.SyncPullParams(sinceHistoryCursor: cursor, want: want)
            let result: BridgeWire.SyncBundleResult
            do {
                result = try session.call(
                    method: BridgeWire.Method.syncPull.rawValue, params: params,
                    resultType: BridgeWire.SyncBundleResult.self)
            } catch { throw EngineError.pull("\(error)") }

            if plan.pull.contains(.vocabulary), let v = result.bundle.vocabulary {
                pulled.vocabulary = store.applyVocabulary(v)
            }
            if plan.pull.contains(.profiles), let p = result.bundle.profiles {
                pulled.profiles = store.applyProfiles(p)
            }
            if plan.pull.contains(.modes), let m = result.bundle.modes {
                pulled.modes = store.applyModes(m)
            }
            if plan.pull.contains(.history) {
                pulled.history = store.applyHistory(result.historyEntries)
            }
            // packs: content-hash identity handled by the app's pack installer; the
            // engine reports the section as seen but does not merge binaries here.
        }

        // 4. Push: offer our sections the plan flagged. Re-snapshot AFTER the pull
        // so a just-merged remote edit is included in what we push back — this is
        // what makes a two-way sync converge in a single round.
        if !plan.push.isEmpty {
            let after = store.snapshot()
            let bundle = Self.bundle(from: after, sections: plan.push)
            let entries = plan.push.contains(.history) ? after.history : []
            let params = BridgeWire.SyncBundleResult(bundle: bundle, historyEntries: entries)
            let result: BridgeWire.SyncPushResult
            do {
                result = try session.call(
                    method: BridgeWire.Method.syncPush.rawValue, params: params,
                    resultType: BridgeWire.SyncPushResult.self)
            } catch { throw EngineError.push("\(error)") }
            if result.accepted {
                pushed = SyncReport.SectionCounts(
                    vocabulary: result.mergedCounts.vocabulary,
                    profiles: result.mergedCounts.profiles,
                    modes: result.mergedCounts.modes,
                    history: result.mergedCounts.history,
                    packs: result.mergedCounts.packs)
            }
        }

        return SyncReport(pulled: pulled, pushed: pushed, startedAt: started, finishedAt: now())
    }

    // MARK: - Wire ⇄ core mapping

    /// Build a `ConfigBundle` carrying only the requested config sections (history
    /// rides separately as full `TranscriptionEntry`s).
    static func bundle(from state: SyncManifestBuilder.LocalState, sections: Set<SyncSection>) -> ConfigBundle {
        ConfigBundle(
            schemaVersion: ConfigBundle.currentSchemaVersion,
            profiles: sections.contains(.profiles) ? state.profiles : nil,
            modes: sections.contains(.modes) ? state.modes : nil,
            vocabulary: sections.contains(.vocabulary) ? state.vocabulary : nil
        )
    }

    /// Map a wire manifest into the pure ``SyncManifest`` the planner consumes.
    static func manifest(from wire: BridgeWire.SyncManifestResult) -> SyncManifest {
        var stamps: [SyncSection: Date] = [:]
        for (raw, iso) in wire.updatedAt {
            guard let section = SyncSection(rawValue: raw), let date = BridgeWire.date(fromISO8601: iso) else { continue }
            stamps[section] = date
        }
        let head = SyncHistoryHead(
            count: wire.historyHead.count,
            newestID: wire.historyHead.newestID,
            newestDate: wire.historyHead.newestDate.flatMap(BridgeWire.date(fromISO8601:)))
        return SyncManifest(
            schemaVersion: wire.schemaVersion,
            vocabHash: wire.vocabHash,
            profilesHash: wire.profilesHash,
            modesHash: wire.modesHash,
            packsHash: wire.packsHash,
            historyHead: head,
            updatedAt: stamps)
    }
}
