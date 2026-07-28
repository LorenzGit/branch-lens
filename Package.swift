// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BranchLens",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "BranchLensCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BranchLens",
            dependencies: ["BranchLensCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BranchLensCoreTests",
            dependencies: ["BranchLensCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
