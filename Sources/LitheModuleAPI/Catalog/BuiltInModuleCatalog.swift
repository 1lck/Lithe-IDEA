import Foundation

/// Stable, platform-neutral declarations shared by macOS and Windows.
/// Platform composition roots provide factories; they must not redefine IDs,
/// scope, or lifecycle defaults.
public enum BuiltInModuleCatalog {
    public static let manifests: [ModuleManifest] = [
        ModuleManifest(
            id: .aiAssistance,
            displayName: "AI Assistance",
            scope: .application,
            defaultState: .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 5 * 60),
            providedCapabilities: [.aiCommitMessage]
        ),
        ModuleManifest(
            id: .database,
            displayName: "Database",
            scope: .workspace,
            defaultState: .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.databaseWorkspace]
        ),
        ModuleManifest(
            id: .debug,
            displayName: "Debug",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [
                .module(.workspace),
                .module(.languageIntelligence),
                .module(.execution)
            ],
            providedCapabilities: [.debugWorkspace]
        ),
        ModuleManifest(
            id: .execution,
            displayName: "Build / Run / Test",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.executionWorkspace]
        ),
        ModuleManifest(
            id: .git,
            displayName: "Git Review",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.gitWorkspace]
        ),
        ModuleManifest(
            id: .languageIntelligence,
            displayName: "Language Intelligence",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.languageIntelligence]
        ),
        ModuleManifest(
            id: .localHistory,
            displayName: "Local History",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.historyWorkspace]
        ),
        ModuleManifest(
            id: .search,
            displayName: "Search & Index",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.searchWorkspace]
        ),
        ModuleManifest(
            id: .terminal,
            displayName: "Terminal",
            scope: .workspace,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.terminalWorkspace]
        ),
        ModuleManifest(
            id: .workspace,
            displayName: "Workspace Foundation",
            scope: .workspace,
            activationPolicy: .eager,
            sleepPolicy: .never,
            providedCapabilities: [.workspaceFoundation],
            isRequired: true
        )
    ].sorted { $0.id < $1.id }

    public static var ids: [ModuleID] { manifests.map(\.id) }

    public static let contributions: [ModuleID: [ModuleContribution]] = [
        .aiAssistance: [
            ModuleContribution(id: "ai.commit-message", kind: .command, title: "Generate Commit Message", icon: "wand.and.stars"),
            ModuleContribution(id: "ai.settings", kind: .settings, title: "AI Assistance", icon: "wand.and.stars")
        ],
        .database: [
            ModuleContribution(id: "database.workspace", kind: .toolWindow, title: "Database", icon: "cylinder")
        ],
        .debug: [
            ModuleContribution(id: "debug.session", kind: .toolWindow, title: "Debug", icon: "ladybug", order: 700, actionID: "debug.toggle", rendererID: "debug.session")
        ],
        .execution: [
            ModuleContribution(id: "execution.maven", kind: .toolWindow, title: "Maven", icon: "shippingbox", order: 400, actionID: "execution.maven.toggle", rendererID: "execution.maven", visibility: ["projectKind": "maven"]),
            ModuleContribution(id: "execution.run", kind: .toolWindow, title: "Run", icon: "play.rectangle", order: 500, actionID: "execution.run.toggle", rendererID: "execution.run"),
            ModuleContribution(id: "execution.tests", kind: .toolWindow, title: "Tests", icon: "checkmark.seal", order: 600, actionID: "execution.tests.toggle", rendererID: "execution.tests")
        ],
        .git: [
            ModuleContribution(id: "git.changes", kind: .toolWindow, title: "Changes", icon: "arrow.triangle.branch"),
            ModuleContribution(id: "git.log", kind: .toolWindow, title: "Git Log", icon: "point.3.connected.trianglepath.dotted", order: 200, actionID: "git.log.toggle", rendererID: "git.log")
        ],
        .languageIntelligence: [
            ModuleContribution(id: "language.problems", kind: .toolWindow, title: "Problems", icon: "exclamationmark.triangle", order: 300, actionID: "language.problems.toggle", rendererID: "language.problems"),
            ModuleContribution(id: "language.settings", kind: .settings, title: "Language Servers", icon: "server.rack")
        ],
        .localHistory: [
            ModuleContribution(id: "history.local", kind: .toolWindow, title: "Local History", icon: "clock.arrow.circlepath")
        ],
        .search: [
            ModuleContribution(id: "search.workspace", kind: .toolWindow, title: "Search", icon: "magnifyingglass")
        ],
        .terminal: [
            ModuleContribution(id: "terminal.sessions", kind: .toolWindow, title: "Terminal", icon: "terminal", order: 100, actionID: "terminal.toggle", rendererID: "terminal.sessions")
        ],
        .workspace: []
    ]

    public static func manifest(for id: ModuleID) -> ModuleManifest? {
        manifests.first { $0.id == id }
    }

    public static func contributions(for id: ModuleID) -> [ModuleContribution] {
        contributions[id] ?? []
    }
}

public enum BuiltInPluginCatalog {
    public static let hostVersion = PluginVersion(major: 0, minor: 3, patch: 0)
    public static let vendor = PluginVendor(
        id: "dev.lithe",
        displayName: "Lithe",
        signatureRequirement: .sameTeamAsHost
    )

    public static let manifests: [PluginManifest] = BuiltInModuleCatalog.manifests.map { manifest in
        let suffix = manifest.id.rawValue.replacingOccurrences(of: "dev.lithe.", with: "")
        return PluginManifest(
            id: PluginID("dev.lithe.plugin.\(suffix)"),
            displayName: manifest.displayName,
            version: hostVersion,
            hostCompatibility: PluginHostCompatibility(
                minimum: hostVersion,
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: vendor,
            entrypoint: .builtIn(targetName: targetName(for: manifest.id)),
            modules: [PluginModuleDeclaration(
                manifest: manifest,
                contributions: BuiltInModuleCatalog.contributions(for: manifest.id)
            )]
        )
    }.sorted { $0.id < $1.id }

    public static func manifest(forModule id: ModuleID) -> PluginManifest? {
        manifests.first { plugin in plugin.modules.contains { $0.manifest.id == id } }
    }

    private static func targetName(for id: ModuleID) -> String {
        switch id {
        case .aiAssistance: "LitheAIAssistanceModule"
        case .database: "LitheDatabaseModule"
        case .debug: "LitheDebugModule"
        case .execution: "LitheExecutionModule"
        case .git: "LitheGitModule"
        case .languageIntelligence: "LitheLanguageIntelligenceModule"
        case .localHistory: "LitheLocalHistoryModule"
        case .search: "LitheSearchModule"
        case .terminal: "LitheTerminalModule"
        case .workspace: "LitheWorkspaceModule"
        default: preconditionFailure("Unknown built-in module \(id)")
        }
    }
}

/// Optional official packages distributed through the same native plugin path
/// as marketplace updates. These manifests are not part of the host's static
/// module graph and become available only when their signed package exists.
public enum OfficialPluginCatalog {
    private static let goLanguageID = "go"

    public static let manifests: [PluginManifest] = [
        PluginManifest(
            id: PluginID("dev.lithe.plugin.go-support"),
            displayName: "Go Support",
            version: BuiltInPluginCatalog.hostVersion,
            hostCompatibility: PluginHostCompatibility(
                minimum: BuiltInPluginCatalog.hostVersion,
                maximumExclusive: PluginVersion(major: 0, minor: 4, patch: 0)
            ),
            vendor: BuiltInPluginCatalog.vendor,
            entrypoint: PluginEntrypoint(
                kind: .nativeBundle,
                bundleIdentifier: "dev.lithe.plugin.go-support.bundle",
                principalClass: "LitheGoSupportPluginEntrypoint",
                bundlePath: "GoSupport.bundle"
            ),
            modules: [
                PluginModuleDeclaration(manifest: ModuleManifest(
                    id: .languageExecutionExtension(goLanguageID),
                    displayName: "Go Execution",
                    scope: .workspace,
                    activationPolicy: .onDemand,
                    sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
                    dependencies: [.module(.workspace)],
                    providedCapabilities: [
                        .languageExecutionExtension(goLanguageID),
                        .languageTestingExtension(goLanguageID)
                    ]
                )),
                PluginModuleDeclaration(manifest: ModuleManifest(
                    id: .languageServerExtension(goLanguageID),
                    displayName: "Go Language Server",
                    scope: .workspace,
                    activationPolicy: .onDemand,
                    sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
                    dependencies: [.module(.workspace)],
                    providedCapabilities: [.languageServerExtension(goLanguageID)]
                ))
            ],
            languageSupports: [LanguageSupportDeclaration(
                id: goLanguageID,
                displayName: "Go",
                fileExtensions: ["go"],
                projectFileNames: ["go.mod", "go.work"],
                languageServerModuleID: .languageServerExtension(goLanguageID),
                executionModuleID: .languageExecutionExtension(goLanguageID),
                testingModuleID: .languageExecutionExtension(goLanguageID)
            )]
        )
    ]

    public static func manifest(forModule id: ModuleID) -> PluginManifest? {
        manifests.first { plugin in plugin.modules.contains { $0.manifest.id == id } }
    }

    public static func moduleManifest(for id: ModuleID) -> ModuleManifest? {
        manifest(forModule: id)?.modules.first { $0.manifest.id == id }?.manifest
    }
}
