// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Lithe",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Lithe", targets: ["Lithe"]),
        .library(name: "LitheModuleAPI", targets: ["LitheModuleAPI"]),
        .library(name: "LitheApplicationKernel", targets: ["LitheApplicationKernel"]),
        .library(name: "LitheCoreContracts", targets: ["LitheCoreContracts"]),
        .library(name: "LitheGitModule", targets: ["LitheGitModule"]),
        .library(name: "LitheSearchModule", targets: ["LitheSearchModule"]),
        .library(name: "LitheLocalHistoryModule", targets: ["LitheLocalHistoryModule"]),
        .library(name: "LitheTerminalModule", targets: ["LitheTerminalModule"]),
        .library(name: "LitheDatabaseModule", targets: ["LitheDatabaseModule"]),
        .library(name: "LitheAIAssistanceModule", targets: ["LitheAIAssistanceModule"]),
        .library(name: "LitheExecutionModule", targets: ["LitheExecutionModule"]),
        .library(name: "LitheDebugModule", targets: ["LitheDebugModule"]),
        .library(name: "LitheLanguageIntelligenceModule", targets: ["LitheLanguageIntelligenceModule"]),
        .library(name: "LitheWorkspaceModule", targets: ["LitheWorkspaceModule"]),
        .library(name: "LitheGoSupportModule", targets: ["LitheGoSupportModule"]),
        .executable(name: "LitheCoreVerifier", targets: ["LitheCoreVerifier"]),
        .executable(name: "LitheGitGraphVerifier", targets: ["LitheGitGraphVerifier"]),
        .executable(name: "LitheGitPerformanceVerifier", targets: ["LitheGitPerformanceVerifier"]),
        .executable(name: "LitheOfficialPluginVerifier", targets: ["LitheOfficialPluginVerifier"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4")
    ],
    targets: [
        .target(
            name: "LitheModuleAPI",
            path: "macos/Sources/LitheModuleAPI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheApplicationKernel",
            dependencies: ["LitheModuleAPI"],
            path: "macos/Sources/LitheApplicationKernel",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheCoreContracts",
            dependencies: ["LitheModuleAPI"],
            path: "macos/Sources/LitheCoreContracts",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheGitModule",
            dependencies: ["LitheModuleAPI", "LitheCoreContracts"],
            path: "macos/Sources/LitheGitModule",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheSearchModule",
            dependencies: ["LitheModuleAPI", "LitheCoreContracts"],
            path: "macos/Sources/LitheSearchModule",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LitheLocalHistoryModule",
            dependencies: ["LitheModuleAPI", "LitheCoreContracts"],
            path: "macos/Sources/LitheLocalHistoryModule",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(name: "LitheTerminalModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "macos/Sources/LitheTerminalModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheDatabaseModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "macos/Sources/LitheDatabaseModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheAIAssistanceModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "macos/Sources/LitheAIAssistanceModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheExecutionModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "macos/Sources/LitheExecutionModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheDebugModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "macos/Sources/LitheDebugModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheLanguageIntelligenceModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "macos/Sources/LitheLanguageIntelligenceModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheWorkspaceModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "macos/Sources/LitheWorkspaceModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheGoSupportModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Plugins/mac/Official/GoSupport/Sources/LitheGoSupportModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "LitheRustCore",
            path: "macos/Sources/LitheRustCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Lithe",
            dependencies: [
                "LitheModuleAPI",
                "LitheApplicationKernel",
                "LitheCoreContracts",
                "LitheGitModule",
                "LitheSearchModule",
                "LitheLocalHistoryModule",
                "LitheTerminalModule",
                "LitheDatabaseModule",
                "LitheAIAssistanceModule",
                "LitheExecutionModule",
                "LitheDebugModule",
                "LitheLanguageIntelligenceModule",
                "LitheWorkspaceModule",
                "LitheRustCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "macos/Sources/Lithe",
            resources: [
                .copy("Resources/MarkdownPreview"),
                .copy("Resources/SyntaxHighlighting"),
                .copy("Resources/WorkbenchBackgrounds")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "LitheTests",
            dependencies: ["Lithe", "LitheModuleAPI", "LitheApplicationKernel", "LitheCoreContracts", "LitheGitModule", "LitheDatabaseModule", "LitheAIAssistanceModule", "LitheLanguageIntelligenceModule", "LitheGoSupportModule", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LitheApplicationKernelTests",
            dependencies: ["LitheModuleAPI", "LitheApplicationKernel", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheApplicationKernelTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LitheTerminalModuleTests",
            dependencies: ["LitheTerminalModule", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheTerminalModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheAIAssistanceModuleTests",
            dependencies: ["LitheAIAssistanceModule", "LitheApplicationKernel", "LitheCoreContracts", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheAIAssistanceModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheSearchModuleTests",
            dependencies: ["LitheSearchModule", "LitheApplicationKernel", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheSearchModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheLocalHistoryModuleTests",
            dependencies: ["LitheLocalHistoryModule", "LitheApplicationKernel", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheLocalHistoryModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheGitModuleTests",
            dependencies: ["LitheGitModule", "LitheApplicationKernel", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheGitModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LitheGitPerformanceSupport",
            dependencies: ["LitheGitModule"],
            path: "macos/Tests/LitheGitPerformanceSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheGitPerformanceTests",
            dependencies: [
                "Lithe",
                "LitheGitModule",
                "LitheGitPerformanceSupport",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "macos/Tests/LitheGitPerformanceTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheDatabaseModuleTests",
            dependencies: ["LitheDatabaseModule", "LitheApplicationKernel", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheDatabaseModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheLanguageIntelligenceModuleTests",
            dependencies: ["LitheLanguageIntelligenceModule", "LitheApplicationKernel", "LitheCoreContracts", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheLanguageIntelligenceModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheDebugModuleTests",
            dependencies: ["LitheDebugModule", "LitheApplicationKernel", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheDebugModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheExecutionModuleTests",
            dependencies: ["LitheExecutionModule", "LitheApplicationKernel", "LitheCoreContracts", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheExecutionModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheWorkspaceModuleTests",
            dependencies: ["LitheWorkspaceModule", "LitheApplicationKernel", .product(name: "Testing", package: "swift-testing")],
            path: "macos/Tests/LitheWorkspaceModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheGoSupportModuleTests",
            dependencies: [
                "LitheGoSupportModule",
                "LitheApplicationKernel",
                "LitheLanguageIntelligenceModule",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Plugins/mac/Official/GoSupport/Tests/LitheGoSupportModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LitheCoreVerifier",
            dependencies: ["LitheCoreContracts", "LitheGitModule", "LitheSearchModule"],
            path: "macos/Tests/LitheCoreVerifier",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LitheGitGraphVerifier",
            dependencies: ["LitheGitModule"],
            path: "macos/Tests/LitheGitGraphVerifier",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LitheGitPerformanceVerifier",
            dependencies: ["LitheGitModule", "LitheGitPerformanceSupport"],
            path: "macos/Tests/LitheGitPerformanceVerifier",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LitheOfficialPluginVerifier",
            dependencies: ["LitheModuleAPI", "LitheApplicationKernel", "LitheCoreContracts"],
            path: "macos/Tests/LitheOfficialPluginVerifier",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
