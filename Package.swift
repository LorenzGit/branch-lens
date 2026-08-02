// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BranchLens",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
    ],
    targets: [
        .target(
            name: "BranchLensCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BranchLens",
            dependencies: [
                "BranchLensCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BranchLensCoreTests",
            dependencies: ["BranchLensCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
