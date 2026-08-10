// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Lithe",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Lithe", targets: ["Lithe"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0")
    ],
    targets: [
        .target(
            name: "LitheRustCore",
            path: "Sources/LitheRustCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Lithe",
            dependencies: [
                "LitheRustCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
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
