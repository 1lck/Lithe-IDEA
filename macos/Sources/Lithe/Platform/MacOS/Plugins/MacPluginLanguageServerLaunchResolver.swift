import LitheModuleAPI
import CryptoKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

// Note: Java 语言服务器插件化与启动计划见 .agents/notes/implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md

/// Writable state of declarative plugins' language servers. It lives outside
/// both the app bundle and the installed plugin packages, which stay
/// read-only, and is removed with the plugin that owns it.
struct MacPluginStateDirectories: Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    init(fileStorage: any FileStorage) {
        self.init(rootURL: fileStorage.applicationSupportDirectory()
            .appendingPathComponent("Lithe/PluginState", isDirectory: true))
    }

    /// Everything the plugin's servers have written, for every language.
    func pluginDirectory(pluginID: String) -> URL {
        rootURL.appendingPathComponent(pluginID, isDirectory: true)
    }

    /// `${stateDir}` of one language server.
    func stateDirectory(pluginID: String, languageID: String) -> URL {
        pluginDirectory(pluginID: pluginID).appendingPathComponent(languageID, isDirectory: true)
    }

    /// `${workspaceStateDir}`: keyed by the workspace root so two projects
    /// never share an index, without putting the user's path in a file name.
    func workspaceStateDirectory(pluginID: String, languageID: String, workspaceRootURL: URL) -> URL {
        stateDirectory(pluginID: pluginID, languageID: languageID)
            .appendingPathComponent("workspaces", isDirectory: true)
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
    private let fileManager: FileManager

    init(
        planner: any DeclarativeLanguageServerLaunchPlanning,
        directories: MacPluginStateDirectories,
        settings: any PluginSettingsStoring,
        fileManager: FileManager = .default
    ) {
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
            workspaceConfiguration: plan.workspaceConfiguration
        )
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
        }

        let executable: Executable
        let arguments: [String]
        let initializationOptions: ToolingJSONValue?
        /// Runtimes the process needs on `PATH`.
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
            projectSettings: settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL)
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
            projectSettings: settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL)
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
            settings: launchSettings
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
            projectSettings: settings.projectValues(forPlugin: pluginID, projectRoot: workspaceRootURL)
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
            throw DeclarativePluginRejection(
                code: "plugin.launch.unavailable",
                message: "Rust Core returned a provider launch without an executable."
            )
        }
        try createRequiredDirectories(of: plan, request: request)
        return BuildProviderProcess(
            executable: executable,
            arguments: plan.arguments,
            initializationOptions: plan.initializationOptions,
            runtimeTools: plan.runtimeRequirements.map(\.tool),
            executesProjectCode: executesProjectCode,
            mayUseNetwork: mayUseNetwork,
            settings: launchSettings
        )
    }

    /// A declared host integration with its resources located in the package.
    struct HostIntegration: Equatable {
        let id: String
        /// Entry file of the runtime launch the integration builds on.
        let entryURL: URL?
        let resources: [String: [URL]]

        func resource(_ name: String) -> URL? { resources[name]?.first }
    }

    /// Locates the files a server's host integration consumes. Every path is
    /// verified to exist inside the package before host code is given it.
    func hostIntegration(for source: DeclarativeLanguageServerLaunchSource) throws -> HostIntegration? {
        let plan = try planner.languageServerLaunchPlan(
            manifest: source.manifest,
            languageID: source.languageID,
            request: request(for: source, workspaceRootURL: source.packageURL)
        )
        guard let integration = plan.hostIntegration else { return nil }
        try verifyPackagePaths(plan.requiredPackagePaths, packageURL: source.packageURL)
        let root = source.packageURL.standardizedFileURL
        return HostIntegration(
            id: integration.id,
            entryURL: plan.entryPath.map { root.appendingPathComponent($0).standardizedFileURL },
            resources: integration.resources.mapValues { paths in
                paths.map { root.appendingPathComponent($0).standardizedFileURL }
            }
        )
    }

    /// How the host checks a candidate executable before using it.
    struct ExecutableProbe: Equatable {
        var validationArguments: [String] = []
        var versionRequirement: LanguageServerExecutableVersionRequirement?
        /// Runtime shipped inside the plugin package. It is the only
        /// executable the host may start for the server.
        var packagedRuntimeURL: URL?
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
            }
        )
    }

    private func request(
        for source: DeclarativeLanguageServerLaunchSource,
        workspaceRootURL: URL
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
            projectSettings: settings.projectValues(forPlugin: source.pluginID, projectRoot: workspaceRootURL)
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
            case .state: request.stateDirectory
            case .workspaceState: request.workspaceStateDirectory
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
