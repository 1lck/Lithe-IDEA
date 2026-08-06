// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Lithe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Lithe", targets: ["Lithe"])
    ],
    targets: [
        .target(
            name: "LitheRustCore",
            path: "Sources/LitheRustCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Lithe",
            dependencies: ["LitheRustCore"],
            path: "Sources/Lithe",
            resources: [
                .copy("Resources/MarkdownPreview")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "LitheTests",
            dependencies: ["Lithe"],
            path: "Tests/LitheTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
