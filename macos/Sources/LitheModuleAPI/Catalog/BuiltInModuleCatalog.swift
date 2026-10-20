import Foundation

/// Stable, platform-neutral declarations shared by macOS and Windows.
/// Platform composition roots provide factories; they must not redefine IDs,
/// scope, or lifecycle defaults.
public enum BuiltInModuleCatalog {
    public static let manifests: [ModuleManifest] = [
        ModuleManifest(
            id: .agentConversation,
            displayName: "Agent Conversation",
            scope: .application,
            defaultState: .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .never,
            providedCapabilities: [.agentConversation]
        ),
        ModuleManifest(
            id: .aiAssistance,
            displayName: "AI Assistance",
            scope: .application,
            defaultState: .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 5 * 60),
            providedCapabilities: [.aiCommitMessage, .aiPullRequestDescription]
        ),
        ModuleManifest(
            id: .database,
            displayName: "Database",
            scope: .workspace,
            defaultState: .enabled,
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
        .agentConversation: [
            ModuleContribution(id: "agent.conversation", kind: .toolWindow, title: "Agent", icon: "sparkles", placement: .rightSidebar, order: 200, actionID: "agent.conversation.toggle", rendererID: "agent.conversation")
        ],
        .aiAssistance: [
            ModuleContribution(id: "ai.commit-message", kind: .command, title: "Generate Commit Message", icon: "wand.and.stars"),
            ModuleContribution(id: "ai.pull-request-description", kind: .command, title: "Generate Pull Request Description", icon: "wand.and.stars"),
            ModuleContribution(id: "ai.settings", kind: .settings, title: "AI Assistance", icon: "wand.and.stars")
        ],
        .database: [
            ModuleContribution(id: "database.workspace", kind: .toolWindow, title: "Database", icon: "cylinder", placement: .rightSidebar, order: 150, actionID: "database.toggle", rendererID: "database.workspace"),
            ModuleContribution(id: "database.services", kind: .toolWindow, title: "Services", icon: "server.rack", order: 450, actionID: "database.services.toggle", rendererID: "database.services")
        ],
        .debug: [
            ModuleContribution(id: "debug.session", kind: .toolWindow, title: "Debug", icon: "ladybug", order: 700, actionID: "debug.toggle", rendererID: "debug.session")
        ],
        .execution: [
            ModuleContribution(id: "execution.build.output", kind: .toolWindow, title: "Build Output", icon: "terminal", order: 410, actionID: "execution.build.output.toggle", rendererID: "execution.build.output"),
            ModuleContribution(id: "execution.run", kind: .toolWindow, title: "Run", icon: "play.rectangle", order: 500, actionID: "execution.run.toggle", rendererID: "execution.run"),
            ModuleContribution(id: "execution.tests", kind: .toolWindow, title: "Tests", icon: "checkmark.seal", order: 600, actionID: "execution.tests.toggle", rendererID: "execution.tests")
        ],
        .git: [
            ModuleContribution(id: "git.changes", kind: .toolWindow, title: "Changes", icon: "arrow.triangle.branch", placement: .leftSidebar, order: 200, actionID: "git.changes.show", rendererID: "git.changes"),
            ModuleContribution(id: "git.log", kind: .toolWindow, title: "Git Log", icon: "point.3.connected.trianglepath.dotted", order: 200, actionID: "git.log.toggle", rendererID: "git.log")
        ],
        .languageIntelligence: [
            ModuleContribution(id: "language.problems", kind: .toolWindow, title: "Problems", icon: "exclamationmark.triangle", order: 300, actionID: "language.problems.toggle", rendererID: "language.problems"),
            ModuleContribution(id: "language.references", kind: .toolWindow, title: "Usages", order: 310, actionID: "language.references.toggle", rendererID: "language.references"),
            ModuleContribution(id: "language.spring", kind: .toolWindow, title: "Spring Endpoints", order: 320, actionID: "language.spring.toggle", rendererID: "language.spring"),
            ModuleContribution(id: "language.settings", kind: .settings, title: "Language Servers", icon: "server.rack")
        ],
        .localHistory: [
            ModuleContribution(id: "history.local", kind: .toolWindow, title: "Local History", icon: "clock.arrow.circlepath")
        ],
        .search: [
            ModuleContribution(id: "search.workspace", kind: .toolWindow, title: "Search", icon: "magnifyingglass", placement: .leftSidebar, order: 400, actionID: "search.workspace.show", rendererID: "search.workspace")
        ],
        .terminal: [
            ModuleContribution(id: "terminal.sessions", kind: .toolWindow, title: "Terminal", icon: "terminal", order: 100, actionID: "terminal.toggle", rendererID: "terminal.sessions")
        ],
        .workspace: [
            ModuleContribution(id: "workspace.project", kind: .toolWindow, title: "Project", placement: .leftSidebar, order: 100, actionID: "workspace.project.show", rendererID: "workspace.project"),
            ModuleContribution(id: "github.pull-requests", kind: .toolWindow, title: "Pull Requests", placement: .leftSidebar, order: 300, actionID: "github.pull-requests.show", rendererID: "github.pull-requests")
        ]
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
        case .agentConversation: "LitheAgentConversationModule"
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

/// Official declarative plugins the host recognizes before they are installed.
/// The host pins each plugin's trust policy so a package cannot downgrade the
/// signature it must carry; the package's own `plugin.json` remains the source
/// of its language and process declarations. Retired official plugins stay
/// listed so installed copies keep that pinned trust policy.
public enum OfficialPluginCatalog {
    public enum Distribution: Equatable, Sendable {
        /// Shipped inside the application bundle and sealed by its signature.
        case bundled
        /// Downloaded on demand as a publisher-signed package.
        case download
        /// No longer published as an official plugin; its successor is the
        /// community plugin with this ID. An installed copy keeps its pinned
        /// signature requirement and keeps loading, but receives no official
        /// updates, so the host asks the user to replace it.
        case migratedToCommunity(PluginID)
    }

    public struct Entry: Equatable, Sendable {
        public let id: PluginID
        public let displayName: String
        public let signatureRequirement: PluginSignatureRequirement
        public let distribution: Distribution
        public let languageID: String
        public let languageDisplayName: String
        /// Used to suggest the plugin for a project before it is installed.
        public let fileExtensions: [String]
        public let projectFileNames: [String]

        /// The community plugin that replaces this retired official plugin.
        public var communityReplacementID: PluginID? {
            guard case .migratedToCommunity(let replacementID) = distribution else { return nil }
            return replacementID
        }
    }

    public static let phpPluginID = PluginID("dev.lithe.plugin.php-support")
    public static let goPluginID = PluginID("dev.lithe.plugin.go-support")
    public static let javaPluginID = PluginID("dev.lithe.plugin.java-support")

    public static let entries: [Entry] = [
        Entry(
            id: javaPluginID,
            displayName: "Java Support",
            signatureRequirement: .sameTeamAsHost,
            distribution: .bundled,
            languageID: "java",
            languageDisplayName: "Java",
            fileExtensions: ["java"],
            projectFileNames: ["pom.xml", "build.gradle", "build.gradle.kts"]
        ),
        Entry(
            id: goPluginID,
            displayName: "Go Support",
            signatureRequirement: .publisherPackage,
            distribution: .migratedToCommunity(PluginID("io.github.lithe-idea.go-support")),
            languageID: "go",
            languageDisplayName: "Go",
            fileExtensions: ["go"],
            projectFileNames: ["go.mod", "go.work"]
        ),
        Entry(
            id: phpPluginID,
            displayName: "PHP Support",
            signatureRequirement: .publisherPackage,
            distribution: .migratedToCommunity(PluginID("io.github.lithe-idea.php-support")),
            languageID: "php",
            languageDisplayName: "PHP",
            fileExtensions: ["php", "phtml"],
            projectFileNames: ["composer.json"]
        )
    ]

    public static func entry(for id: PluginID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// Entries still published as official plugins, which the host may
    /// suggest and whose languages it ties to the official package.
    public static var publishedEntries: [Entry] {
        entries.filter { $0.communityReplacementID == nil }
    }
}

/// Module manifests the host synthesizes for language capabilities, shared by
/// bundled language specifications and declarative plugins so both run under
/// the same lifecycle policy.
public enum LanguageExtensionModuleManifests {
    public static func languageServer(
        languageID: String,
        displayName: String,
        enabledByDefault: Bool = false
    ) -> ModuleManifest {
        ModuleManifest(
            id: .languageServerExtension(languageID),
            displayName: "\(displayName) Language Server",
            scope: .workspace,
            defaultState: enabledByDefault ? .enabled : .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [.languageServerExtension(languageID)]
        )
    }

    public static func execution(languageID: String, displayName: String) -> ModuleManifest {
        ModuleManifest(
            id: .languageExecutionExtension(languageID),
            displayName: "\(displayName) Execution",
            scope: .workspace,
            defaultState: .disabled,
            activationPolicy: .onDemand,
            sleepPolicy: .whenIdle(afterSeconds: 10 * 60),
            dependencies: [.module(.workspace)],
            providedCapabilities: [
                .languageExecutionExtension(languageID),
                .languageTestingExtension(languageID)
            ]
        )
    }

    /// One module for all build systems of a plugin. It owns no process of
    /// its own: the execution module runs the commands while it is enabled.
    public static func buildSystems(
        pluginID: String,
        displayName: String,
        enabledByDefault: Bool = false
    ) -> ModuleManifest {
        ModuleManifest(
            id: .buildSystemsExtension(pluginID),
            displayName: "\(displayName) Build Systems",
            scope: .workspace,
            defaultState: enabledByDefault ? .enabled : .disabled,
            activationPolicy: .onDemand,
            dependencies: [.module(.workspace)]
        )
    }
}
