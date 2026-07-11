// swift-tools-version:6.0
import PackageDescription
import Foundation

// MARK: - Upstream OpenWhispCore dependency (arrives in phase 2, not WP1)
//
// WP1 deliberately ships WITHOUT the OpenWhispCore dependency: `MobileCore` and
// `KeyboardCore` are strictly Foundation-only and must compile with nothing but
// the standard library. The engine work (WP3) is what first `import`s the
// upstream core into `CaptureKit`/`SyncKit`.
//
// When that lands, the dependency is added here. For local co-development you
// will be able to point at a checkout instead of the branch pin by exporting
// `OPENWHISP_CORE_PATH=/path/to/openwhisp` before resolving. The scaffolding
// for that override lives below so the pattern is documented and ready:
//
//   let coreDependency: Package.Dependency = {
//       if let path = ProcessInfo.processInfo.environment["OPENWHISP_CORE_PATH"] {
//           return .package(name: "openwhisp", path: path)
//       }
//       return .package(url: "https://github.com/initcore0/openwhisp.git", branch: "main")
//   }()
//
// Until then there is no external dependency at all.

let package = Package(
    name: "OpenWhispMobileKit",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "MobileCore", targets: ["MobileCore"]),
        .library(name: "KeyboardCore", targets: ["KeyboardCore"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
    ],
    dependencies: [
        // Intentionally empty in WP1. OpenWhispCore is added in phase 2 (see note above).
    ],
    targets: [
        // MARK: Foundation-only cores (the `swift test` surface)
        .target(
            name: "MobileCore",
            dependencies: []
        ),
        .target(
            name: "KeyboardCore",
            dependencies: ["MobileCore"]
        ),

        // MARK: OS-bound conformer homes (placeholders this WP)
        .target(
            name: "CaptureKit",
            dependencies: ["MobileCore"]
        ),
        .target(
            name: "SyncKit",
            dependencies: ["MobileCore"]
        ),

        // MARK: Tests (the gate)
        .testTarget(
            name: "MobileCoreTests",
            dependencies: ["MobileCore"]
        ),
        .testTarget(
            name: "KeyboardCoreTests",
            dependencies: ["KeyboardCore", "MobileCore"]
        ),
    ],
    // Swift 5 language mode (the repo targets Swift 5.9+); tools-version 6.0 is
    // required only because `.iOS(.v18)` is unavailable to older PackageDescription.
    swiftLanguageModes: [.v5]
)
