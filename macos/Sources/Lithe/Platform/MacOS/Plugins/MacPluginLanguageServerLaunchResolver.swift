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
        let digest = SHA256.hash(data: Data(workspaceRootURL.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return stateDirectory(pluginID: pluginID, languageID: languageID)
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
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

        var errorDescription: String? {
            switch self {
            case .missingPackagePath(let path):
                "The plugin package is missing \(path). Reinstall the plugin."
            case .packagePathOutsidePackage(let path):
                "The plugin launch refers to \(path), which is not a file inside its package."
            }
        }
    }

    private let planner: any DeclarativeLanguageServerLaunchPlanning
    private let directories: MacPluginStateDirectories
    private let fileManager: FileManager

    init(
        planner: any DeclarativeLanguageServerLaunchPlanning,
        directories: MacPluginStateDirectories,
        fileManager: FileManager = .default
    ) {
        self.planner = planner
        self.directories = directories
        self.fileManager = fileManager
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
            architecture: Self.hostArchitecture
        )
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
