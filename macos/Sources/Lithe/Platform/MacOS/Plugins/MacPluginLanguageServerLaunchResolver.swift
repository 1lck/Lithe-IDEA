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
                "The plugin package is missing \(path). Reinstall the plugin."
            case .packagePathOutsidePackage(let path):
                "The plugin launch refers to \(path), which is not a file inside its package."
            case .packagedExecutableNotRunnable(let path):
                "The plugin package's \(path) is not an executable file. Reinstall the plugin."
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

    /// The plugin's stored setting values a launch expands with now. A
    /// provider started with other values is out of date.
    func settingValues(forPlugin pluginID: String) -> [String: ToolingJSONValue] {
        settings.values(forPlugin: pluginID)
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
        for directory in plan.requiredDirectories {
            let url = switch directory {
            case .state: request.stateDirectory
            case .workspaceState: request.workspaceStateDirectory
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return ResolvedLanguageServerLaunch(
            arguments: plan.arguments,
            initializationOptions: plan.initializationOptions
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
        let settingValues = settings.values(forPlugin: pluginID)
        let request = DeclarativeLanguageServerLaunchRequest(
            pluginDirectory: packageURL.standardizedFileURL,
            stateDirectory: directories.buildSystemStateDirectory(pluginID: pluginID, buildSystemID: buildSystemID),
            workspaceStateDirectory: directories.buildSystemWorkspaceStateDirectory(
                pluginID: pluginID,
                buildSystemID: buildSystemID,
                workspaceRootURL: workspaceRootURL
            ),
            architecture: Self.hostArchitecture,
            settings: settingValues
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
        for directory in plan.requiredDirectories {
            let url = switch directory {
            case .state: request.stateDirectory
            case .workspaceState: request.workspaceStateDirectory
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return .process(BuildProviderProcess(
            executable: executable,
            arguments: plan.arguments,
            initializationOptions: plan.initializationOptions,
            runtimeTools: plan.runtimeRequirements.map(\.tool),
            executesProjectCode: provider.executesProjectCode,
            mayUseNetwork: provider.mayUseNetwork,
            settings: settingValues
        ))
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
            settings: settings.values(forPlugin: source.pluginID)
        )
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
