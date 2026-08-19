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
        .executable(name: "LitheOfficialPluginVerifier", targets: ["LitheOfficialPluginVerifier"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0")
    ],
    targets: [
        .target(
            name: "LitheModuleAPI",
            path: "Sources/LitheModuleAPI",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheApplicationKernel",
            dependencies: ["LitheModuleAPI"],
            path: "Sources/LitheApplicationKernel",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheCoreContracts",
            dependencies: ["LitheModuleAPI"],
            path: "Sources/LitheCoreContracts",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheGitModule",
            dependencies: ["LitheModuleAPI", "LitheCoreContracts"],
            path: "Sources/LitheGitModule",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "LitheSearchModule",
            dependencies: ["LitheModuleAPI", "LitheCoreContracts"],
            path: "Sources/LitheSearchModule",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LitheLocalHistoryModule",
            dependencies: ["LitheModuleAPI", "LitheCoreContracts"],
            path: "Sources/LitheLocalHistoryModule",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(name: "LitheTerminalModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheTerminalModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheDatabaseModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheDatabaseModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheAIAssistanceModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheAIAssistanceModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheExecutionModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheExecutionModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheDebugModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheDebugModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheLanguageIntelligenceModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheLanguageIntelligenceModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheWorkspaceModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheWorkspaceModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "LitheGoSupportModule", dependencies: ["LitheModuleAPI", "LitheCoreContracts"], path: "Sources/LitheGoSupportModule", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "LitheRustCore",
            path: "Sources/LitheRustCore",
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
            path: "Sources/Lithe",
            resources: [
                .copy("Resources/MarkdownPreview"),
                .copy("Resources/SyntaxHighlighting")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "LitheTests",
            dependencies: ["Lithe", "LitheModuleAPI", "LitheApplicationKernel", "LitheCoreContracts", "LitheGitModule", "LitheDatabaseModule", "LitheAIAssistanceModule", "LitheLanguageIntelligenceModule", "LitheGoSupportModule"],
            path: "Tests/LitheTests",
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LitheApplicationKernelTests",
            dependencies: ["LitheModuleAPI", "LitheApplicationKernel"],
            path: "Tests/LitheApplicationKernelTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LitheTerminalModuleTests",
            dependencies: ["LitheTerminalModule"],
            path: "Tests/LitheTerminalModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheAIAssistanceModuleTests",
            dependencies: ["LitheAIAssistanceModule", "LitheApplicationKernel", "LitheCoreContracts"],
            path: "Tests/LitheAIAssistanceModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheSearchModuleTests",
            dependencies: ["LitheSearchModule", "LitheApplicationKernel"],
            path: "Tests/LitheSearchModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheLocalHistoryModuleTests",
            dependencies: ["LitheLocalHistoryModule", "LitheApplicationKernel"],
            path: "Tests/LitheLocalHistoryModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheGitModuleTests",
            dependencies: ["LitheGitModule", "LitheApplicationKernel"],
            path: "Tests/LitheGitModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheDatabaseModuleTests",
            dependencies: ["LitheDatabaseModule", "LitheApplicationKernel"],
            path: "Tests/LitheDatabaseModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheLanguageIntelligenceModuleTests",
            dependencies: ["LitheLanguageIntelligenceModule", "LitheApplicationKernel", "LitheCoreContracts"],
            path: "Tests/LitheLanguageIntelligenceModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheDebugModuleTests",
            dependencies: ["LitheDebugModule", "LitheApplicationKernel"],
            path: "Tests/LitheDebugModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheExecutionModuleTests",
            dependencies: ["LitheExecutionModule", "LitheApplicationKernel", "LitheCoreContracts"],
            path: "Tests/LitheExecutionModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheWorkspaceModuleTests",
            dependencies: ["LitheWorkspaceModule", "LitheApplicationKernel"],
            path: "Tests/LitheWorkspaceModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LitheGoSupportModuleTests",
            dependencies: [
                "LitheGoSupportModule",
                "LitheApplicationKernel",
                "LitheLanguageIntelligenceModule"
            ],
            path: "Tests/LitheGoSupportModuleTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LitheCoreVerifier",
            dependencies: ["LitheCoreContracts", "LitheGitModule", "LitheSearchModule"],
            path: "Tests/LitheCoreVerifier",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LitheGitGraphVerifier",
            dependencies: ["LitheGitModule"],
            path: "Tests/LitheGitGraphVerifier",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LitheOfficialPluginVerifier",
            dependencies: ["LitheModuleAPI", "LitheApplicationKernel", "LitheCoreContracts"],
            path: "Tests/LitheOfficialPluginVerifier",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
