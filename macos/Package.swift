// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Folio",
    // Keep in sync with the deployment target in build.zig.
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FolioKit", targets: ["FolioKit"]),
        .executable(name: "Folio", targets: ["Folio"]),
    ],
    targets: [
        // Built by `zig build` from the repository root.
        .binaryTarget(name: "CFolio", path: "CFolio.xcframework"),
        .target(name: "FolioKit", dependencies: ["CFolio"]),
        .executableTarget(name: "Folio", dependencies: ["FolioKit"]),
        .testTarget(name: "FolioKitTests", dependencies: ["FolioKit"]),
    ]
)
