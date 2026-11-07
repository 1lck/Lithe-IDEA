import LitheModuleAPI
import CryptoKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

// Note: 语言服务器插件化与启动计划见 .agents/notes/implemented/architecture/2026-10-12-declarative-language-plugins.md

/// Writable state of declarative plugins' language servers. It lives outside
/// both the app bundle and the installed plugin packages, which stay
/// read-only, and is removed with the plugin that owns it.
struct MacPluginStateDirectories: Sendable {
    let rootURL: URL
    /// Holds the scratch directory of each start of a backend-launched
    /// server. Scratch files are disposable, so they live in the temporary
    /// area, not beside the state a plugin keeps.
    let temporaryRootURL: URL

    init(rootURL: URL, temporaryRootURL: URL? = nil) {
        self.rootURL = rootURL.standardizedFileURL
        self.temporaryRootURL = (temporaryRootURL ?? Self.defaultTemporaryRoot(FileManager.default.temporaryDirectory))
            .standardizedFileURL
    }

    init(fileStorage: any FileStorage) {
        self.init(
            rootURL: fileStorage.applicationSupportDirectory()
                .appendingPathComponent("Lithe/PluginState", isDirectory: true),
            temporaryRootURL: Self.defaultTemporaryRoot(fileStorage.temporaryDirectory())
        )
    }

    private static func defaultTemporaryRoot(_ temporaryDirectory: URL) -> URL {
        temporaryDirectory.appendingPathComponent("lithe-plugin-launch", isDirectory: true)
    }

    /// `${temporaryDirectory}` of one start of a backend-launched server: a
    /// fresh directory whose owner removes it when the process ends.
    func launchScratchDirectory() -> URL {
        temporaryRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Everything the plugin's servers have written, for every language.
    func pluginDirectory(pluginID: String) -> URL {
        rootURL.appendingPathComponent(pluginID, isDirectory: true)
    }

    /// `${stateDir}` of one language server.
    func stateDirectory(pluginID: String, languageID: String) -> URL {
        pluginDirectory(pluginID: pluginID).appendingPathComponent(languageID, isDirectory: true)
    }

    /// Holds one `${workspaceStateDir}` per workspace of one language server.
    func workspaceStatesDirectory(pluginID: String, languageID: String) -> URL {
        stateDirectory(pluginID: pluginID, languageID: languageID)
            .appendingPathComponent("workspaces", isDirectory: true)
    }

    /// `${workspaceStateDir}`: keyed by the workspace root so two projects
    /// never share an index, without putting the user's path in a file name.
    func workspaceStateDirectory(pluginID: String, languageID: String, workspaceRootURL: URL) -> URL {
        workspaceStatesDirectory(pluginID: pluginID, languageID: languageID)
            .appendingPathComponent(Self.workspaceDigest(workspaceRootURL), isDirectory: true)
    }

    /// `${stateDir}` of one build system's provider process.
    func buildSystemStateDirectory(pluginID: String, buildSystemID: String) -> URL {
        pluginDirectory(pluginID: pluginID)
            .appendingPathComponent("build-systems", isDirectory: true)
            .appendingPathComponent(buildSystemID, isDirectory: true)
    }

    /// `${workspaceStateDir}` of one build system: the plugin's build tools
    /// and its language servers never share a directory.
    func buildSystemWorkspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceRootURL: URL) -> URL {
        buildSystemStateDirectory(pluginID: pluginID, buildSystemID: buildSystemID)
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(Self.workspaceDigest(workspaceRootURL), isDirectory: true)
    }

    /// `${stateDir}` of one VCS provider process.
    func vcsProviderStateDirectory(pluginID: String, vcs: String) -> URL {
        pluginDirectory(pluginID: pluginID)
            .appendingPathComponent("vcs-providers", isDirectory: true)
            .appendingPathComponent(vcs, isDirectory: true)
    }

    /// `${stateDir}` of the plugin backend, also its root and working
    /// directory. It goes with the plugin directory on uninstall.
    func backendStateDirectory(pluginID: String) -> URL {
        pluginDirectory(pluginID: pluginID).appendingPathComponent("backend", isDirectory: true)
    }

    /// `${stateDir}` of one debug adapter process. It goes with the plugin
    /// directory on uninstall.
    func debugAdapterStateDirectory(pluginID: String, adapterID: String) -> URL {
        pluginDirectory(pluginID: pluginID)
            .appendingPathComponent("debug-adapters", isDirectory: true)
            .appendingPathComponent(adapterID, isDirectory: true)
    }

    /// `${workspaceStateDir}` of one VCS provider.
    func vcsProviderWorkspaceStateDirectory(pluginID: String, vcs: String, workspaceRootURL: URL) -> URL {
        vcsProviderStateDirectory(pluginID: pluginID, vcs: vcs)
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(Self.workspaceDigest(workspaceRootURL), isDirectory: true)
    }

    static func workspaceDigest(_ workspaceRootURL: URL) -> String {
        SHA256.hash(data: Data(workspaceRootURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Turns a declarative language server's launch templates into the arguments
/// and initialization options of one start. Rust Core expands the templates;
/// this adapter supplies the host directories, verifies that every package
/// path the launch points at is a real file inside the package, and creates
/// the state directories the plan asks for.
struct MacPluginLanguageServerLaunchResolver {
    enum ResolutionError: LocalizedError, Equatable {
        case missingPackagePath(String)
        case packagePathOutsidePackage(String)
        case packagedExecutableNotRunnable(String)

        var errorDescription: String? {
            switch self {
            case .missingPackagePath(let path):
                L10n.string("The plugin package is missing \(path). Reinstall the plugin.")
            case .packagePathOutsidePackage(let path):
                L10n.string("The plugin launch refers to \(path), which is not a file inside its package.")
            case .packagedExecutableNotRunnable(let path):
                L10n.string("The plugin package's \(path) is not an executable file. Reinstall the plugin.")
            }
        }
    }

    private let planner: any DeclarativeLanguageServerLaunchPlanning
    private let directories: MacPluginStateDirectories
    private let settings: any PluginSettingsStoring
    private let logDirectory: @Sendable (String) throws -> URL?
    private let fileManager: FileManager

    init(
        planner: any DeclarativeLanguageServerLaunchPlanning,
        directories: MacPluginStateDirectories,
        settings: any PluginSettingsStoring,
        fileManager: FileManager = .default,
        logDirectory: @escaping @Sendable (String) throws -> URL? = { _ in nil }
    ) {
        self.logDirectory = logDirectory
        self.planner = planner
        self.directories = directories
        self.settings = settings
        self.fileManager = fileManager
    }

    /// The plugin's stored setting values a launch in `workspaceRootURL`
    /// expands with now, both layers in one map (project values under a
    /// `project:` prefix). A provider started with other values is out of date.
    func settingValues(forPlugin pluginID: String, workspaceRootURL: URL) -> [String: ToolingJSONValue] {
        var values = settings.values(forPlugin: pluginID)
        for (id, value) in settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL) {
            values["project:\(id)"] = value
        }
        return values
    }

    func globalSettingValues(forPlugin pluginID: String) -> [String: ToolingJSONValue] {
        settings.values(forPlugin: pluginID)
    }

    func projectSettingValues(forPlugin pluginID: String, workspaceRootURL: URL) -> [String: ToolingJSONValue] {
        settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL)
    }

    static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    func resolve(
        _ source: DeclarativeLanguageServerLaunchSource,
        workspaceRootURL: URL
    ) throws -> ResolvedLanguageServerLaunch {
        let request = request(for: source, workspaceRootURL: workspaceRootURL)
        let plan = try planner.languageServerLaunchPlan(
            manifest: source.manifest,
            languageID: source.languageID,
            request: request
        )
        try verifyPackagePaths(plan.requiredPackagePaths, packageURL: source.packageURL)
        try createRequiredDirectories(of: plan, request: request)
        return ResolvedLanguageServerLaunch(
            arguments: plan.arguments,
            initializationOptions: plan.initializationOptions,
            workspaceConfiguration: plan.workspaceConfiguration,
            sessionPolicy: plan.sessionPolicy
        )
    }

    // MARK: Backend-resolved launches (`serverProcess` 3)

    /// The first step of a launch the plugin's backend decides: what to ask
    /// the backend, with the directories this start owns. The second step
    /// needs the same request, so the question carries it.
    struct BackendLaunchQuestion: Equatable {
        let function: String
        let timeoutMilliseconds: Int
        /// Params of the function; the host adds the workspace `context`.
        let resolveParams: [String: ToolingJSONValue]
        /// Removed by the owner of the process once it ends.
        let scratchDirectory: URL
        let request: DeclarativeLanguageServerLaunchRequest
    }

    /// What the backend's answer asks the host to start, after Core bounded
    /// it and the package paths were verified.
    struct BackendLaunchProcess: Equatable {
        enum Program: Equatable {
            /// A runnable file inside the plugin package.
            case file(URL)
            /// A tool definition of the plugin, resolved by the host.
            case tool(String)
        }

        let program: Program
        let environment: [String: String]
        let launch: ResolvedLanguageServerLaunch
    }

    func backendLaunchQuestion(
        for source: DeclarativeLanguageServerLaunchSource,
        workspaceRootURL: URL
    ) throws -> BackendLaunchQuestion {
        let scratch = directories.launchScratchDirectory()
        let request = request(for: source, workspaceRootURL: workspaceRootURL, temporaryDirectory: scratch)
        do {
            let plan = try planner.languageServerLaunchPlan(
                manifest: source.manifest, languageID: source.languageID, request: request
            )
            guard let resolution = plan.backendResolution else {
                throw DeclarativePluginRejection(
                    code: "plugin.launch.notBackend",
                    message: "Rust Core returned a launch plan without a question for the plugin backend."
                )
            }
            try createRequiredDirectories(of: plan, request: request)
            return BackendLaunchQuestion(
                function: resolution.function,
                timeoutMilliseconds: resolution.timeoutMilliseconds,
                resolveParams: resolution.resolveParams,
                scratchDirectory: scratch,
                request: request
            )
        } catch {
            // The caller gets no question to clean up after, so the
            // directory the plan may already have created goes here.
            // log-exempt: 清理只是尽力而为，调用方要处理的是上面抛出的原始错误
            try? fileManager.removeItem(at: scratch)
            throw error
        }
    }

    /// Has Rust Core check the backend's answer, then verifies the files it
    /// names and creates the parents of the paths the process writes.
    func backendLaunchProcess(
        for source: DeclarativeLanguageServerLaunchSource,
        question: BackendLaunchQuestion,
        answer: ToolingJSONValue
    ) throws -> BackendLaunchProcess {
        let plan = try planner.decodeLaunch(
            manifest: source.manifest, languageID: source.languageID, request: question.request, result: answer
        )
        guard let resolved = plan.resolvedLaunch else {
            throw DeclarativePluginRejection(
                code: "plugin.launch.invalidResult",
                message: "Rust Core returned a decoded launch without a program."
            )
        }
        let program = try backendProgram(resolved.program, packageURL: source.packageURL)
        for path in resolved.writablePaths {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }
        return BackendLaunchProcess(
            program: program,
            environment: resolved.environment,
            launch: ResolvedLanguageServerLaunch(
                arguments: plan.arguments,
                initializationOptions: plan.initializationOptions,
                workspaceConfiguration: plan.workspaceConfiguration,
                sessionPolicy: plan.sessionPolicy
            )
        )
    }

    /// A packaged program must be a runnable file inside the package; a tool
    /// is only a name here, because the host resolves it later.
    private func backendProgram(
        _ program: DeclarativeLanguageServerLaunchPlan.ResolvedLaunch.Program,
        packageURL: URL
    ) throws -> BackendLaunchProcess.Program {
        switch program {
        case .packaged(let path):
            let file = try packagedExecutable(path, packageURL: packageURL.standardizedFileURL)
            return .file(file)
        case .tool(let tool):
            return .tool(tool)
        }
    }

    /// How a build system's provider answers, after Core expanded its launch.
    enum BuildProviderLaunch: Equatable {
        /// The language server of the same plugin answers; no process starts.
        case languageServer(String)
        case process(BuildProviderProcess)
    }

    /// A provider process of its own, with every package path verified and
    /// its state directories created.
    struct BuildProviderProcess: Equatable {
        enum Executable: Equatable {
            /// A file inside the package, the plugin's own runtime included.
            case file(URL)
            /// Command names the host's tool discovery resolves, in order.
            case commands([String])
            /// A runtime the host discovers with the user's settings.
            case runtime(String, versionRequirement: LanguageServerExecutableVersionRequirement?)
            /// A tool definition the host resolves through its four layers, or the
            /// runtime the plugin ships. The definition's `launch` template places
            /// the entry and runtime arguments, and `arguments` fill `${arguments}`.
            case tool(DefinedToolProcessLaunch)
        }

        let executable: Executable
        let arguments: [String]
        let initializationOptions: ToolingJSONValue?
        /// Runtimes the process needs on `PATH`. Under a tool launch these
        /// are only the closed-list runtimes; `.tool` resolves the others.
        let runtimeTools: [String]
        let executesProjectCode: Bool
        let mayUseNetwork: Bool
        /// The setting values the launch was expanded with.
        let settings: [String: ToolingJSONValue]
    }

    /// Expands the provider launch of one build system for one workspace.
    /// Its `${stateDir}` and `${workspaceStateDir}` belong to the build
    /// system, so the provider never writes into a language server's state.
    func resolveBuildProvider(
        pluginID: String,
        buildSystemID: String,
        manifest: Data,
        packageURL: URL,
        workspaceRootURL: URL
    ) throws -> BuildProviderLaunch {
        let launchSettings = self.settingValues(forPlugin: pluginID, workspaceRootURL: workspaceRootURL)
        let request = DeclarativeLanguageServerLaunchRequest(
            pluginDirectory: packageURL.standardizedFileURL,
            stateDirectory: directories.buildSystemStateDirectory(pluginID: pluginID, buildSystemID: buildSystemID),
            workspaceStateDirectory: directories.buildSystemWorkspaceStateDirectory(
                pluginID: pluginID,
                buildSystemID: buildSystemID,
                workspaceRootURL: workspaceRootURL
            ),
            architecture: Self.hostArchitecture,
            settings: settings.values(forPlugin: pluginID),
            projectSettings: settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL),
            logDirectory: try? logDirectory(pluginID)
        )
        let plan = try planner.buildProviderLaunchPlan(
            manifest: manifest,
            buildSystemID: buildSystemID,
            request: request
        )
        guard let provider = plan.buildProvider, provider.buildSystemID == buildSystemID else {
            throw DeclarativePluginRejection(
                code: "plugin.launch.unavailable",
                message: "Rust Core returned no provider for \(buildSystemID)."
            )
        }
        if let languageID = provider.languageServer { return .languageServer(languageID) }
        return .process(try providerProcess(
            plan, request: request, packageURL: packageURL,
            executesProjectCode: provider.executesProjectCode, mayUseNetwork: provider.mayUseNetwork,
            settings: launchSettings
        ))
    }

    /// A VCS provider process with every package path verified and its
    /// state directories created. The VCS client is resolved separately and
    /// named in each request.
    struct VcsProviderProcess: Equatable {
        let process: BuildProviderProcess
        let vcs: String
        let toolCommands: [String]
        let toolValidationArguments: [String]
    }

    /// Expands the provider launch of one VCS for one workspace. Its state
    /// directories belong to the provider, apart from the plugin's language
    /// servers and build systems.
    func resolveVcsProvider(
        pluginID: String,
        vcs: String,
        manifest: Data,
        packageURL: URL,
        workspaceRootURL: URL
    ) throws -> VcsProviderProcess {
        let launchSettings = self.settingValues(forPlugin: pluginID, workspaceRootURL: workspaceRootURL)
        let request = DeclarativeLanguageServerLaunchRequest(
            pluginDirectory: packageURL.standardizedFileURL,
            stateDirectory: directories.vcsProviderStateDirectory(pluginID: pluginID, vcs: vcs),
            workspaceStateDirectory: directories.vcsProviderWorkspaceStateDirectory(
                pluginID: pluginID,
                vcs: vcs,
                workspaceRootURL: workspaceRootURL
            ),
            architecture: Self.hostArchitecture,
            settings: settings.values(forPlugin: pluginID),
            projectSettings: settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL),
            logDirectory: try? logDirectory(pluginID)
        )
        let plan = try planner.vcsProviderLaunchPlan(manifest: manifest, vcs: vcs, request: request)
        guard let provider = plan.vcsProvider, provider.vcs == vcs else {
            throw DeclarativePluginRejection(
                code: "plugin.launch.unavailable",
                message: "Rust Core returned no VCS provider for \(vcs)."
            )
        }
        let process = try providerProcess(
            plan, request: request, packageURL: packageURL,
            executesProjectCode: false, mayUseNetwork: provider.mayUseNetwork, settings: launchSettings
        )
        return VcsProviderProcess(
            process: process,
            vcs: vcs,
            toolCommands: provider.toolCommands,
            toolValidationArguments: provider.toolValidationArguments
        )
    }

    /// The plugin backend's process, with the host services the session may
    /// request. It belongs to no workspace, so its launch has no
    /// `${workspaceStateDir}` and no project settings.
    struct BackendProcess: Equatable {
        let process: BuildProviderProcess
        let hostServices: [String]
        /// `${stateDir}`, created; the session's root and working directory.
        let stateDirectory: URL
    }

    /// The setting values a backend launch expands with now: the global
    /// layer only, since a backend belongs to no project.
    func backendSettingValues(forPlugin pluginID: String) -> [String: ToolingJSONValue] {
        settings.values(forPlugin: pluginID)
    }

    func resolveBackend(pluginID: String, manifest: Data, packageURL: URL) throws -> BackendProcess {
        let launchSettings = backendSettingValues(forPlugin: pluginID)
        let stateDirectory = directories.backendStateDirectory(pluginID: pluginID)
        let request = DeclarativeLanguageServerLaunchRequest(
            pluginDirectory: packageURL.standardizedFileURL,
            stateDirectory: stateDirectory,
            workspaceStateDirectory: nil,
            architecture: Self.hostArchitecture,
            settings: launchSettings,
            logDirectory: try? logDirectory(pluginID)
        )
        let plan = try planner.backendLaunchPlan(manifest: manifest, request: request)
        guard let backend = plan.backend else {
            throw DeclarativePluginRejection(
                code: "plugin.launch.unavailable",
                message: "Rust Core returned no backend for \(pluginID)."
            )
        }
        let process = try providerProcess(
            plan, request: request, packageURL: packageURL,
            executesProjectCode: false, mayUseNetwork: true, settings: launchSettings
        )
        // The session starts in this directory even when no argument names it.
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        return BackendProcess(process: process, hostServices: backend.hostServices, stateDirectory: stateDirectory)
    }

    /// How a debug adapter is reached once Core expanded its launch. The DAP
    /// `adapterID` and the supported requests come from Rust Core's descriptor.
    struct DebugAdapterLaunch: Equatable {
        enum Host: Equatable {
            /// A process of its own, with every package path verified and its
            /// state directories created.
            case process(BuildProviderProcess)
            /// Hosted by the plugin's own language server: no process starts
            /// here, the server's session does, and `command` makes it listen.
            case languageServer(languageID: String, command: String)
        }

        let host: Host
        let adapter: DeclarativeLanguageServerLaunchPlan.DebugAdapter
    }

    /// Expands the launch of one debug adapter for one workspace. A packaged
    /// executable or a system command over stdio, or an adapter hosted by the
    /// plugin's language server, is supported; the adapter never writes into
    /// the package.
    func resolveDebugAdapter(
        pluginID: String,
        adapterID: String,
        manifest: Data,
        packageURL: URL,
        workspaceRootURL: URL
    ) throws -> DebugAdapterLaunch {
        let launchSettings = self.settingValues(forPlugin: pluginID, workspaceRootURL: workspaceRootURL)
        let stateDirectory = directories.debugAdapterStateDirectory(pluginID: pluginID, adapterID: adapterID)
        let request = DeclarativeLanguageServerLaunchRequest(
            pluginDirectory: packageURL.standardizedFileURL,
            stateDirectory: stateDirectory,
            workspaceStateDirectory: stateDirectory
                .appendingPathComponent("workspaces", isDirectory: true)
                .appendingPathComponent(MacPluginStateDirectories.workspaceDigest(workspaceRootURL), isDirectory: true),
            architecture: Self.hostArchitecture,
            settings: settings.values(forPlugin: pluginID),
            projectSettings: settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL),
            logDirectory: try? logDirectory(pluginID)
        )
        let plan = try planner.debugAdapterLaunchPlan(manifest: manifest, adapterID: adapterID, request: request)
        guard let adapter = plan.debugAdapter, adapter.id == adapterID else {
            throw DeclarativePluginRejection(
                code: "plugin.launch.unavailable",
                message: L10n.string("The plugin does not provide the debug adapter \(adapterID).")
            )
        }
        // The adapter lives inside the plugin's language server: the plan is
        // that server's launch, which its own session performs, so nothing
        // starts or is created here.
        if adapter.transport == "tcpLanguageServer" {
            guard let endpoint = adapter.languageServerEndpoint else {
                throw DeclarativePluginRejection(
                    code: "plugin.launch.unavailable",
                    message: L10n.string("The debug adapter \(adapterID) names no language server to host it."),
                    field: "debugAdapters.launch.endpoint"
                )
            }
            return DebugAdapterLaunch(
                host: .languageServer(languageID: endpoint.languageID, command: endpoint.command),
                adapter: adapter
            )
        }
        // Any other TCP adapter would be started and then never reached, so
        // refuse before the process exists.
        guard adapter.transport == "stdio" else {
            throw DeclarativePluginRejection(
                code: "plugin.launch.unsupportedTransport",
                message: L10n.string(
                    "The debug adapter \(adapterID) uses the \(adapter.transport) transport, which Lithe cannot start yet. Only stdio and language server hosted adapters are supported."
                ),
                field: "debugAdapters.launch.transport"
            )
        }
        switch plan.executable {
        case .packaged?, .systemCommand?: break
        default:
            throw DeclarativePluginRejection(
                code: "plugin.launch.unavailable",
                message: L10n.string("The debug adapter \(adapterID) must launch a packaged executable or a system command.")
            )
        }
        let process = try providerProcess(
            plan, request: request, packageURL: packageURL,
            executesProjectCode: true, mayUseNetwork: false, settings: launchSettings
        )
        return DebugAdapterLaunch(host: .process(process), adapter: adapter)
    }

    /// The executable of a plan's own process, with its package paths
    /// verified and state directories created.
    private func providerProcess(
        _ plan: DeclarativeLanguageServerLaunchPlan,
        request: DeclarativeLanguageServerLaunchRequest,
        packageURL: URL,
        executesProjectCode: Bool,
        mayUseNetwork: Bool,
        settings launchSettings: [String: ToolingJSONValue]
    ) throws -> BuildProviderProcess {
        try verifyPackagePaths(plan.requiredPackagePaths, packageURL: packageURL)
        let root = packageURL.standardizedFileURL
        let executable: BuildProviderProcess.Executable
        switch plan.executable {
        case .packaged(let path)?:
            executable = .file(try packagedExecutable(path, packageURL: root))
        case .systemCommand(let commands)?:
            executable = .commands(commands)
        case .runtime(let tool)?:
            executable = if let path = plan.packagedRuntimePath {
                .file(try packagedExecutable(path, packageURL: root))
            } else {
                .runtime(tool, versionRequirement: plan.executableVersionRequirement)
            }
        case nil:
            // A tool launch names no executable; its definition starts it.
            guard let launch = plan.toolLaunch else {
                throw DeclarativePluginRejection(
                    code: "plugin.launch.unavailable",
                    message: "Rust Core returned a provider launch without an executable."
                )
            }
            executable = .tool(try toolProcess(launch, plan: plan, packageURL: root))
        }
        try createRequiredDirectories(of: plan, request: request)
        return BuildProviderProcess(
            executable: executable,
            arguments: plan.arguments,
            initializationOptions: plan.initializationOptions,
            runtimeTools: Self.closedListRuntimeTools(of: plan),
            executesProjectCode: executesProjectCode,
            mayUseNetwork: mayUseNetwork,
            settings: launchSettings
        )
    }

    /// A tool launch with the runtime the plugin ships, when it ships one,
    /// checked to be a runnable file inside the package.
    private func toolProcess(
        _ launch: DeclarativeLanguageServerLaunchPlan.ToolLaunch,
        plan: DeclarativeLanguageServerLaunchPlan,
        packageURL: URL
    ) throws -> DefinedToolProcessLaunch {
        DefinedToolProcessLaunch(
            launch: launch,
            packagedRuntimeURL: try launch.packagedRuntime.map { try packagedExecutable($0, packageURL: packageURL) },
            requirements: plan.runtimeRequirements.filter(\.resolvesThroughDefinition)
        )
    }

    /// The runtimes the host's closed list puts on `PATH`. A tool launch
    /// resolves its definition requirements itself, so they are left out;
    /// every other launch keeps all of them as before.
    private static func closedListRuntimeTools(of plan: DeclarativeLanguageServerLaunchPlan) -> [String] {
        guard plan.toolLaunch != nil else { return plan.runtimeRequirements.map(\.tool) }
        return plan.runtimeRequirements.filter { !$0.resolvesThroughDefinition }.map(\.tool)
    }

    /// A language server whose launch names a tool definition: the plan is
    /// expanded for the workspace, its package paths verified and its
    /// directories created. The caller resolves the tool when it starts and
    /// expands the command line with `launch.arguments` as `${arguments}`.
    func resolveToolLaunch(
        _ source: DeclarativeLanguageServerLaunchSource,
        workspaceRootURL: URL
    ) throws -> (process: DefinedToolProcessLaunch, runtimeTools: [String], launch: ResolvedLanguageServerLaunch) {
        let request = request(for: source, workspaceRootURL: workspaceRootURL)
        let plan = try planner.languageServerLaunchPlan(
            manifest: source.manifest,
            languageID: source.languageID,
            request: request
        )
        guard let launch = plan.toolLaunch else {
            throw DeclarativePluginRejection(
                code: "plugin.launch.unavailable",
                message: "Rust Core returned no tool launch for \(source.languageID)."
            )
        }
        try verifyPackagePaths(plan.requiredPackagePaths, packageURL: source.packageURL)
        let process = try toolProcess(launch, plan: plan, packageURL: source.packageURL.standardizedFileURL)
        try createRequiredDirectories(of: plan, request: request)
        return (
            process: process,
            runtimeTools: Self.closedListRuntimeTools(of: plan),
            launch: ResolvedLanguageServerLaunch(
                arguments: plan.arguments,
                initializationOptions: plan.initializationOptions,
                workspaceConfiguration: plan.workspaceConfiguration,
                sessionPolicy: plan.sessionPolicy
            )
        )
    }

    /// How the host checks a candidate executable before using it.
    struct ExecutableProbe: Equatable {
        var validationArguments: [String] = []
        var versionRequirement: LanguageServerExecutableVersionRequirement?
        /// Runtime shipped inside the plugin package. It is the only
        /// executable the host may start for the server.
        var packagedRuntimeURL: URL?
        /// True when the launch names a tool definition. The host then has no
        /// executable to look up or probe; it resolves the tool at each start.
        var launchesThroughTool = false
    }

    /// Probe of the server's executable. The contract forbids state
    /// directories in probe arguments, so no workspace is needed to expand them.
    func executableProbe(for source: DeclarativeLanguageServerLaunchSource) throws -> ExecutableProbe {
        let plan = try planner.languageServerLaunchPlan(
            manifest: source.manifest,
            languageID: source.languageID,
            request: request(for: source, workspaceRootURL: source.packageURL)
        )
        return ExecutableProbe(
            validationArguments: plan.validationArguments,
            versionRequirement: plan.executableVersionRequirement,
            packagedRuntimeURL: plan.packagedRuntimePath.map {
                source.packageURL.appendingPathComponent($0).standardizedFileURL
            },
            launchesThroughTool: plan.toolLaunch != nil
        )
    }

    private func request(
        for source: DeclarativeLanguageServerLaunchSource,
        workspaceRootURL: URL,
        temporaryDirectory: URL? = nil
    ) -> DeclarativeLanguageServerLaunchRequest {
        DeclarativeLanguageServerLaunchRequest(
            pluginDirectory: source.packageURL.standardizedFileURL,
            stateDirectory: directories.stateDirectory(
                pluginID: source.pluginID,
                languageID: source.languageID
            ),
            workspaceStateDirectory: directories.workspaceStateDirectory(
                pluginID: source.pluginID,
                languageID: source.languageID,
                workspaceRootURL: workspaceRootURL
            ),
            architecture: Self.hostArchitecture,
            settings: settings.values(forPlugin: source.pluginID),
            projectSettings: settings.projectValues(forPlugin: source.pluginID, projectRoot: workspaceRootURL),
            // Log storage is optional unless the template requires it. Core
            // rejects a missing logDirectory only for a launch using ${logDir}.
            logDirectory: try? logDirectory(source.pluginID),
            temporaryDirectory: temporaryDirectory
        )
    }

    /// Creates the state directories the plan expands into. Core refuses a
    /// workspace directory the request did not give, so a missing one here
    /// means the plan and request disagree.
    private func createRequiredDirectories(
        of plan: DeclarativeLanguageServerLaunchPlan,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws {
        for directory in plan.requiredDirectories {
            let url: URL? = switch directory {
            case .log: request.logDirectory
            case .state: request.stateDirectory
            case .workspaceState: request.workspaceStateDirectory
            case .temporary: request.temporaryDirectory
            }
            guard let url else {
                throw DeclarativePluginRejection(
                    code: "plugin.launch.invalidRequest",
                    message: "The launch needs a workspace state directory, but it belongs to no workspace."
                )
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// A packaged file the host starts: inside the package, reached without
    /// a symbolic link, a regular file, and executable. Installation checks
    /// the same; this guards a package changed on disk since.
    private func packagedExecutable(_ relativePath: String, packageURL: URL) throws -> URL {
        try verifyPackagePaths([relativePath], packageURL: packageURL)
        let url = packageURL.appendingPathComponent(relativePath).standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true, fileManager.isExecutableFile(atPath: url.path) else {
            throw ResolutionError.packagedExecutableNotRunnable(relativePath)
        }
        return url
    }

    /// A launch may only point at files or directories that exist inside the
    /// package. Symbolic links are refused at every level so a package cannot
    /// make the host hand another program or directory to the server.
    private func verifyPackagePaths(_ relativePaths: [String], packageURL: URL) throws {
        let root = packageURL.standardizedFileURL
        for relativePath in relativePaths {
            var current = root
            for component in relativePath.split(separator: "/") {
                current.appendPathComponent(String(component))
                let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard let values else {
                    throw ResolutionError.missingPackagePath(relativePath)
                }
                guard values.isSymbolicLink != true else {
                    throw ResolutionError.packagePathOutsidePackage(relativePath)
                }
            }
            guard current.path.hasPrefix(root.path + "/") else {
                throw ResolutionError.packagePathOutsidePackage(relativePath)
            }
        }
    }
}
