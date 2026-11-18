// swift-tools-version: 5.9
import PackageDescription

// LanternfallKit holds everything that does not need SpriteKit or UIKit:
// content models + JSON, the fixed-step simulation, and all gameplay systems.
// It builds on macOS, iOS and Linux, so `swift test` runs anywhere.
let package = Package(
    name: "LanternfallKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LanternfallKit", targets: ["LanternfallKit"]),
    ],
    targets: [
        .target(
            name: "LanternfallKit",
            resources: [.copy("Data/Content")]
        ),
        .testTarget(
            name: "LanternfallKitTests",
            dependencies: ["LanternfallKit"]
        ),
    ]
)
