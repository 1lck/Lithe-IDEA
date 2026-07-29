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
        .executableTarget(
            name: "Lithe",
            path: "Sources/Lithe"
        )
    ]
)
