// swift-tools-version:6.0
import PackageDescription
import Foundation

// MARK: - Upstream OpenWhispCore dependency (WP3 engine layer)
//
// WP1 shipped WITHOUT this dependency: `MobileCore` and `KeyboardCore` are
// strictly Foundation-only and must keep compiling with nothing but the standard
// library. WP3 (this phase) is what first `import`s the upstream core — but ONLY
// into `CaptureKit`, where the OS-bound engine conformers live. MobileCore and
// KeyboardCore stay dependency-free.
//
// Local co-development override: export `OPENWHISP_CORE_PATH=/path/to/openwhisp`
// before resolving to point the core dependency at a local checkout instead of the
// branch pin. This is how you iterate on upstream `mak-51-ios-core` (the WP0 iOS
// consumability branch) and the mobile package together without pushing.
//
//   OPENWHISP_CORE_PATH=/Users/you/projects/openwhisp swift build
//
let coreDependency: Package.Dependency = {
    if let path = ProcessInfo.processInfo.environment["OPENWHISP_CORE_PATH"], !path.isEmpty {
        return .package(name: "openwhisp", path: path)
    }
    // Branch pin until the upstream core is tagged (ARCHITECTURE §3: switch to
    // `.upToNextMinor(from:)` at first TestFlight).
    //
    // WP6 pins `mak-51-lan-server` — the complete upstream sync branch (WP0b
    // wire + the Mac LAN server + the coordinator's review fixes): it carries the
    // `sync.manifest`/`sync.pull`/`sync.push` verbs, ConfigBundle schema v3
    // (`updatedAt` stamps), the frame-cap-safe pull PAGING fields
    // (`SyncPullParams.pageCursor`, `SyncBundleResult.hasMoreHistory` /
    // `nextHistoryCursor`), and `TranscriptionEntry` as the fidelity history
    // payload — everything SyncKit consumes. The coordinator flips this back to
    // `main` once the upstream sync branch merges.
    return .package(url: "https://github.com/initcore0/openwhisp.git", branch: "mak-51-lan-server")
}()

let package = Package(
    name: "OpenWhispMobileKit",
    platforms: [
        .iOS(.v18),
        // macOS floor is what `swift test` builds against on a Mac host (the
        // always-green gate). It must be ≥ every dependency's macOS floor: FluidAudio
        // pins .macOS(.v14). This does NOT ship a macOS product — the app targets are
        // iOS-only — it just lets the pure-logic + fake-driven tests run fast on the
        // CI host without a simulator, exactly as the working agreement requires.
        .macOS(.v14),
    ],
    products: [
        .library(name: "MobileCore", targets: ["MobileCore"]),
        .library(name: "KeyboardCore", targets: ["KeyboardCore"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        // SyncCore: the PURE, OS-free sync logic (models + planner + merge).
        // Depends on OpenWhispCore only (ConfigBundle/Vocabulary/TranscriptionEntry)
        // — NOT on Network/Security — so it lives in the fast `swift test` gate.
        // It is a SEPARATE target from MobileCore on purpose: MobileCore is
        // Foundation-only and links into the memory-tight keyboard extension, so it
        // must never pull OpenWhispCore in. SyncKit (OS-bound) builds on SyncCore.
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
    ],
    dependencies: [
        coreDependency,
        // Parakeet (NVIDIA Parakeet CoreML ASR) — the PRIMARY engine (D5). Pinned
        // EXACT to match the mac repo's vendored `third_party/fluidaudio-dep`
        // (0.15.5). FluidAudio's pre-1.0 streaming API surface churns across minors
        // (0.14 → 0.15); the mac `ParakeetBridge` this package ports is written
        // against 0.15.5 exactly, so we pin the same. FluidAudio declares iOS 17+.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        // WhisperKit — the SECONDARY engine (~100-language long tail). Pinned to the
        // SAME fork + revision the mac repo vendors in `third_party/whisperkit-dep`:
        // `initcore0/argmax-oss-swift` (argmaxinc renamed the repo to
        // `argmax-oss-swift`) at v1.0.0 + a single-file backport of upstream PR #503
        // (inputDeviceID passthrough). Pinned by exact commit (immutable). The fork
        // declares iOS 16+, so it links into an iOS app. See PR description for the
        // argmaxinc/WhisperKit-vs-fork note.
        .package(
            url: "https://github.com/initcore0/argmax-oss-swift.git",
            revision: "7e5f648249fde3eeabab02250529f63f16476e91"
        ),
    ],
    targets: [
        // MARK: Foundation-only cores (the `swift test` surface) — NO external deps.
        .target(
            name: "MobileCore",
            dependencies: []
        ),
        .target(
            name: "KeyboardCore",
            dependencies: ["MobileCore"]
        ),

        // MARK: OS-bound conformer home — the engine layer (WP3).
        // CaptureKit gets OpenWhispCore (protocol seams + pure Parakeet/cleaner/VAD
        // types), FluidAudio (Parakeet), and WhisperKit. MobileCore/KeyboardCore
        // never see these.
        .target(
            name: "CaptureKit",
            dependencies: [
                "MobileCore",
                .product(name: "OpenWhispCore", package: "openwhisp"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        // MARK: Pure sync logic — the `swift test` surface (no Network/Security).
        // Models (PeerIdentity, PairingPayload, SyncManifest/Plan/Report) + the
        // SyncPlanner and the pure merge functions (vocab union by id/updatedAt,
        // history append-only union by id, LWW profiles/modes). Imports
        // OpenWhispCore for the shared ConfigBundle/Vocabulary/TranscriptionEntry
        // types the merge operates on — nothing OS-bound.
        .target(
            name: "SyncCore",
            dependencies: [
                .product(name: "OpenWhispCore", package: "openwhisp"),
            ]
        ),

        // MARK: OS-bound sync transport + engine (Network.framework + Keychain).
        // Bonjour discovery (NWBrowser), TLS-PSK NWConnection, the NDJSON
        // BridgeSession conformer, KeychainSecretStore, PairingService, SyncEngine.
        // Builds on SyncCore (pure logic) + OpenWhispBridgeKit (BridgeSession +
        // BridgeWire). `swift test` builds this on the macOS host — Network +
        // Security are available there — so the framing + keychain tests run in the
        // fast gate; camera/DataScanner is iOS-only and lives in the host app UI.
        .target(
            name: "SyncKit",
            dependencies: [
                "MobileCore",
                "SyncCore",
                .product(name: "OpenWhispCore", package: "openwhisp"),
                .product(name: "OpenWhispBridgeKit", package: "openwhisp"),
            ]
        ),

        // MARK: Tests (the gate)
        .testTarget(
            name: "SyncCoreTests",
            dependencies: [
                "SyncCore",
                .product(name: "OpenWhispCore", package: "openwhisp"),
            ]
        ),
        .testTarget(
            name: "SyncKitTests",
            dependencies: [
                "SyncKit",
                "SyncCore",
                .product(name: "OpenWhispCore", package: "openwhisp"),
                .product(name: "OpenWhispBridgeKit", package: "openwhisp"),
            ]
        ),
        .testTarget(
            name: "MobileCoreTests",
            dependencies: ["MobileCore"]
        ),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KeyboardCore", "MobileCore"]
        ),
        // CaptureKit tests: engine-agnostic — protocol fakes + in-memory handoff,
        // no network/models/simulator. Real-engine paths are gated behind
        // OPENWHISP_E2E_ENGINES=1 (see CaptureKitTests/README).
        .testTarget(
            name: "CaptureKitTests",
            dependencies: ["CaptureKit", "MobileCore"],
            // Fixture WAV(s) for the opt-in real-engine E2E (OPENWHISP_E2E_ENGINES=1).
            // Copied so the bundle carries them; the always-green fake tests don't
            // touch these.
            resources: [.copy("Fixtures")]
        ),
    ],
    // Swift 5 language mode (matches upstream OpenWhispCore, which pins .v5 so the
    // tools-version 6.0 bump introduces zero strict-concurrency behavior change).
    swiftLanguageModes: [.v5]
)
