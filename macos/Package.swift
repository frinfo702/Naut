// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Naut",
    // Keep in sync with the deployment target in build.zig.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NautKit", targets: ["NautKit"]),
        .executable(name: "Naut", targets: ["Naut"]),
    ],
    targets: [
        // Built by `zig build` from the repository root.
        .binaryTarget(name: "CNaut", path: "CNaut.xcframework"),
        .target(name: "NautKit", dependencies: ["CNaut"]),
        .executableTarget(name: "Naut", dependencies: ["NautKit"]),
        .testTarget(name: "NautKitTests", dependencies: ["NautKit"]),
    ]
)
