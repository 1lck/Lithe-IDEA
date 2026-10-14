import Foundation
import LitheModuleAPI

// Note: 声明式插件的归属与加载流程见 .agents/notes/implemented/architecture/2026-10-12-declarative-language-plugins.md

/// Stable refusal of a declarative manifest or plan request. `code` is one of
/// the `plugin.*` codes in shared/contracts/plugins/v1/README.md.
public struct DeclarativePluginRejection: Error, Equatable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let field: String?

    public init(code: String, message: String, field: String? = nil) {
        self.code = code
        self.message = message
        self.field = field
    }

    public var errorDescription: String? { message }

    /// Run workflows already present path failures with their own message.
    public var runError: any Error {
        code == "plugin.path.invalid" ? LanguageRunExtensionError.invalidRelativePath : self
    }

    public func testError(languageID: String) -> any Error {
        switch code {
        case "plugin.path.invalid": LanguageTestExtensionError.invalidRelativePath
        case "plugin.test.invalidIdentifier": LanguageTestExtensionError.invalidTestIdentifier
        case "plugin.test.unsupportedProject": LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        default: self
        }
    }
}

public struct DeclarativeLanguageServer: Equatable, Sendable {
    public enum Launch: Equatable, Sendable {
        /// Executable inside the plugin package, relative to its root.
        case packaged(relativePath: String)
        /// Bare command names resolved by the host's tool discovery.
        case systemCommand([String])
        /// Entry file inside the package, started by a runtime such as `java`
        /// or `node` (plugin API 2). `packagedRuntime` is the template of the
        /// runtime the plugin ships, for example `runtime/${arch}/bin/java`;
        /// `nil` means the host discovers the tool.
        case runtime(tool: String, entryRelativePath: String, packagedRuntime: String?)
    }

    public let languageID: String
    public let languageIdentifier: String
    public let launch: Launch
    public let arguments: [String]
    public let validationArguments: [String]
    /// Runtimes the host discovers for the server, such as `node`.
    public let runtimeTools: [String]
    /// True from plugin API 2 on, where arguments are launch templates that
    /// Rust Core expands with host directories before the server starts.
    public let expandsLaunchTemplates: Bool
    /// Native host integration the server declares, such as `jdt`. The host
    /// enables that integration for this server instead of matching on its
    /// language ID.
    public let hostIntegrationID: String?

    /// Path inside the plugin package for a packaged server.
    public var packagedRelativePath: String? {
        if case .packaged(let relativePath) = launch { relativePath } else { nil }
    }

    /// Command names the host's tool discovery resolves for a system command.
    /// A packaged server reports its file name for display only; the host
    /// launches the pinned path inside its own package.
    public var executableNames: [String] {
        switch launch {
        case .packaged(let relativePath):
            [relativePath.split(separator: "/").last.map(String.init) ?? relativePath]
        case .systemCommand(let commands):
            commands
        case .runtime(let tool, _, _):
            // The runtime is the process the host starts; the entry file is
            // an argument of the expanded launch plan.
            [tool]
        }
    }
}

/// Identifies the declaration a language server's launch plan is expanded
/// from. It is plain data so launch descriptors stay comparable.
public struct DeclarativeLanguageServerLaunchSource: Hashable, Sendable {
    public let pluginID: String
    public let languageID: String
    /// Normalized `plugin.json` returned by `plugins.declarative.validate`.
    public let manifest: Data
    /// Root of the installed, read-only plugin package.
    public let packageURL: URL

    public init(pluginID: String, languageID: String, manifest: Data, packageURL: URL) {
        self.pluginID = pluginID
        self.languageID = languageID
        self.manifest = manifest
        self.packageURL = packageURL
    }
}

/// Version a discovered executable must report before the host uses it. The
/// probe arguments come from Rust Core, so the host needs no per-tool rules.
public struct LanguageServerExecutableVersionRequirement: Hashable, Sendable {
    public let tool: String
    public let minimumVersion: String
    /// Arguments that make the tool print its version and exit.
    public let probeArguments: [String]

    public init(tool: String, minimumVersion: String, probeArguments: [String]) {
        self.tool = tool
        self.minimumVersion = minimumVersion
        self.probeArguments = probeArguments
    }
}

/// Outcome of `plugins.declarative.checkRuntimeVersion`.
public struct LanguageServerRuntimeVersionCheck: Equatable, Sendable {
    public let satisfied: Bool
    /// Version read from the probe output; `nil` when it contained none.
    public let version: String?

    public init(satisfied: Bool, version: String?) {
        self.satisfied = satisfied
        self.version = version
    }
}

/// Host directories substituted into a server's launch templates.
public struct DeclarativeLanguageServerLaunchRequest: Equatable, Sendable {
    public let pluginDirectory: URL
    public let stateDirectory: URL
    public let workspaceStateDirectory: URL
    /// `arm64` or `x86_64`.
    public let architecture: String

    public init(
        pluginDirectory: URL,
        stateDirectory: URL,
        workspaceStateDirectory: URL,
        architecture: String
    ) {
        self.pluginDirectory = pluginDirectory
        self.stateDirectory = stateDirectory
        self.workspaceStateDirectory = workspaceStateDirectory
        self.architecture = architecture
    }
}

/// Result of `plugins.declarative.languageServerLaunchPlan`. Rust Core only
/// joins text; the host creates the directories and checks the package paths.
public struct DeclarativeLanguageServerLaunchPlan: Equatable, Sendable {
    public enum RequiredDirectory: String, Sendable {
        case state
        case workspaceState
    }

    public struct RuntimeRequirement: Equatable, Sendable {
        public let tool: String
        public let minimumVersion: String?

        public init(tool: String, minimumVersion: String?) {
            self.tool = tool
            self.minimumVersion = minimumVersion
        }
    }

    /// Complete argument list after the executable.
    public let arguments: [String]
    public let validationArguments: [String]
    public let initializationOptions: ToolingJSONValue?
    /// A declared host integration with its package-relative resource paths.
    public struct HostIntegration: Equatable, Sendable {
        public let id: String
        /// Resource name to one or more package-relative paths, in declared order.
        public let resources: [String: [String]]

        public init(id: String, resources: [String: [String]]) {
            self.id = id
            self.resources = resources
        }
    }

    /// Package-relative entry file of a runtime launch.
    public let entryPath: String?
    public let hostIntegration: HostIntegration?
    /// Package-relative path of the runtime the plugin ships, when it does.
    /// The host starts exactly this file instead of discovering the tool.
    public let packagedRuntimePath: String?
    /// Set for a discovered runtime that must meet a minimum version.
    public let executableVersionRequirement: LanguageServerExecutableVersionRequirement?
    public let runtimeRequirements: [RuntimeRequirement]
    public let requiredDirectories: [RequiredDirectory]
    /// Package-relative paths the launch points at.
    public let requiredPackagePaths: [String]

    public init(
        arguments: [String],
        validationArguments: [String] = [],
        initializationOptions: ToolingJSONValue? = nil,
        entryPath: String? = nil,
        hostIntegration: HostIntegration? = nil,
        packagedRuntimePath: String? = nil,
        executableVersionRequirement: LanguageServerExecutableVersionRequirement? = nil,
        runtimeRequirements: [RuntimeRequirement] = [],
        requiredDirectories: [RequiredDirectory] = [],
        requiredPackagePaths: [String] = []
    ) {
        self.arguments = arguments
        self.validationArguments = validationArguments
        self.initializationOptions = initializationOptions
        self.entryPath = entryPath
        self.hostIntegration = hostIntegration
        self.packagedRuntimePath = packagedRuntimePath
        self.executableVersionRequirement = executableVersionRequirement
        self.runtimeRequirements = runtimeRequirements
        self.requiredDirectories = requiredDirectories
        self.requiredPackagePaths = requiredPackagePaths
    }
}

public struct DeclarativeExecutionProvider: Equatable, Sendable {
    public let languageID: String
    public let providesRun: Bool
    public let providesTest: Bool
}

/// A manifest accepted by `plugins.declarative.validate`, in the normalized
/// form Rust Core returned. Hosts never interpret command templates
/// themselves; they pass `normalizedManifest` back to Core to expand them.
public struct DeclarativePluginDescriptor: Equatable, Sendable {
    public let pluginManifest: PluginManifest
    public let languageServers: [DeclarativeLanguageServer]
    public let executionProviders: [DeclarativeExecutionProvider]
    public let permissions: [String]
    public let activationEvents: [String]
    public let normalizedManifest: Data

    public var id: PluginID { pluginManifest.id }

    /// - Parameter enabledByDefault: `true` for a package that ships inside
    ///   the application. It replaces a built-in feature, so it must work on
    ///   first launch; a downloaded plugin stays off until the user enables it.
    public init(normalizedManifest: Data, enabledByDefault: Bool = false) throws {
        let decoded = try JSONDecoder().decode(NormalizedManifest.self, from: normalizedManifest)
        guard let version = PluginVersion(decoded.version) else {
            throw DeclarativePluginRejection(
                code: "plugin.manifest.invalid",
                message: "The plugin version must use major.minor.patch.",
                field: "version"
            )
        }
        let displayNames = Dictionary(uniqueKeysWithValues: decoded.languages.map { ($0.id, $0.displayName) })
        languageServers = decoded.languageServers.map { server in
            DeclarativeLanguageServer(
                languageID: server.languageID,
                languageIdentifier: server.languageIdentifier ?? server.languageID,
                launch: Self.launch(server.launch),
                arguments: server.arguments,
                validationArguments: server.validationArguments,
                runtimeTools: server.runtimeDependencies.map(\.tool),
                expandsLaunchTemplates: decoded.pluginAPIVersion >= 2,
                hostIntegrationID: server.hostIntegration?.id
            )
        }
        executionProviders = decoded.executionProviders.map { provider in
            DeclarativeExecutionProvider(
                languageID: provider.languageID,
                providesRun: provider.run != nil,
                providesTest: provider.test != nil
            )
        }
        permissions = decoded.permissions
        activationEvents = decoded.activationEvents
        self.normalizedManifest = normalizedManifest

        let serverLanguages = Set(languageServers.map(\.languageID))
        // Rust Core has already refused a capability the integration does not
        // provide, so a name unknown here comes from a newer contract and is
        // a feature this host cannot supply.
        let hostCapabilitiesByLanguage = Dictionary(
            decoded.languageServers.map { server in
                (
                    server.languageID,
                    Set((server.hostIntegration?.capabilities ?? []).compactMap {
                        LanguageHostCapability(rawValue: $0)
                    })
                )
            },
            uniquingKeysWith: { $0.union($1) }
        )
        let executionByLanguage = Dictionary(uniqueKeysWithValues: executionProviders.map { ($0.languageID, $0) })
        var modules = languageServers.map { server in
            PluginModuleDeclaration(manifest: LanguageExtensionModuleManifests.languageServer(
                languageID: server.languageID,
                displayName: displayNames[server.languageID] ?? server.languageID,
                enabledByDefault: enabledByDefault
            ))
        }
        modules += executionProviders.map { provider in
            PluginModuleDeclaration(manifest: LanguageExtensionModuleManifests.execution(
                languageID: provider.languageID,
                displayName: displayNames[provider.languageID] ?? provider.languageID
            ))
        }
        let languageSupports = decoded.languages.map { language in
            let execution = executionByLanguage[language.id]
            return LanguageSupportDeclaration(
                id: language.id,
                displayName: language.displayName,
                fileExtensions: language.fileExtensions,
                fileNames: language.fileNames,
                projectFileNames: language.projectFileNames,
                dependencies: language.dependencies.map {
                    LanguageDependencyDeclaration(
                        managementFileNames: $0.managementFileNames,
                        projectDependencyPaths: $0.projectDependencyPaths,
                        projectBinaryPaths: $0.projectBinaryPaths
                    )
                },
                languageServerModuleID: serverLanguages.contains(language.id)
                    ? .languageServerExtension(language.id)
                    : nil,
                // One execution module serves both run and test capabilities.
                executionModuleID: execution?.providesRun == true
                    ? .languageExecutionExtension(language.id)
                    : nil,
                testingModuleID: execution?.providesTest == true
                    ? .languageExecutionExtension(language.id)
                    : nil,
                hostCapabilities: hostCapabilitiesByLanguage[language.id] ?? []
            )
        }
        pluginManifest = PluginManifest(
            schemaVersion: PluginManifest.declarativeSchemaVersion,
            id: PluginID(decoded.id),
            displayName: decoded.displayName,
            version: version,
            apiVersion: decoded.pluginAPIVersion,
            // Unused for declarative packages: compatibility is decided by the
            // plugin API level, never by the Lithe application version.
            hostCompatibility: PluginHostCompatibility(minimum: PluginVersion(major: 0, minor: 0, patch: 0)),
            vendor: PluginVendor(
                id: decoded.vendor.id,
                displayName: decoded.vendor.displayName,
                signatureRequirement: decoded.vendor.signatureRequirement
            ),
            entrypoint: .declarative,
            modules: modules,
            languageSupports: languageSupports
        )
    }

    private static func launch(_ launch: NormalizedManifest.Launch) -> DeclarativeLanguageServer.Launch {
        switch launch.kind {
        case "packaged":
            .packaged(relativePath: launch.path ?? "")
        case "runtime":
            .runtime(
                tool: launch.tool ?? "",
                entryRelativePath: launch.entry ?? "",
                packagedRuntime: launch.packagedRuntime
            )
        default:
            .systemCommand(launch.commands ?? [])
        }
    }

    /// Mirrors the manifest fields the host needs. Optional lists default to
    /// empty so the same decoder reads Rust Core's normalized output and an
    /// unnormalized `plugin.json` in packaging checks.
    private struct NormalizedManifest: Decodable {
        struct Vendor: Decodable {
            let id: String
            let displayName: String
            let signatureRequirement: PluginSignatureRequirement
        }
        struct Dependencies: Decodable {
            let managementFileNames: [String]
            let projectDependencyPaths: [String]
            let projectBinaryPaths: [String]

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                managementFileNames = try values.decodeIfPresent([String].self, forKey: .managementFileNames) ?? []
                projectDependencyPaths = try values.decodeIfPresent([String].self, forKey: .projectDependencyPaths) ?? []
                projectBinaryPaths = try values.decodeIfPresent([String].self, forKey: .projectBinaryPaths) ?? []
            }

            private enum CodingKeys: String, CodingKey {
                case managementFileNames, projectDependencyPaths, projectBinaryPaths
            }
        }
        struct Language: Decodable {
            let id: String
            let displayName: String
            let fileExtensions: [String]
            let fileNames: [String]
            let projectFileNames: [String]
            let dependencies: Dependencies?

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                displayName = try values.decode(String.self, forKey: .displayName)
                fileExtensions = try values.decodeIfPresent([String].self, forKey: .fileExtensions) ?? []
                fileNames = try values.decodeIfPresent([String].self, forKey: .fileNames) ?? []
                projectFileNames = try values.decodeIfPresent([String].self, forKey: .projectFileNames) ?? []
                dependencies = try values.decodeIfPresent(Dependencies.self, forKey: .dependencies)
            }

            private enum CodingKeys: String, CodingKey {
                case id, displayName, fileExtensions, fileNames, projectFileNames, dependencies
            }
        }
        struct Launch: Decodable {
            let kind: String
            let path: String?
            let commands: [String]?
            let tool: String?
            let entry: String?
            let packagedRuntime: String?
        }
        struct RuntimeDependency: Decodable {
            let tool: String
        }
        struct HostIntegration: Decodable {
            let id: String
            let capabilities: [String]?
        }
        struct LanguageServer: Decodable {
            let languageID: String
            let languageIdentifier: String?
            let launch: Launch
            let arguments: [String]
            let validationArguments: [String]
            let runtimeDependencies: [RuntimeDependency]
            let hostIntegration: HostIntegration?

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                languageID = try values.decode(String.self, forKey: .languageID)
                languageIdentifier = try values.decodeIfPresent(String.self, forKey: .languageIdentifier)
                launch = try values.decode(Launch.self, forKey: .launch)
                arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
                validationArguments = try values.decodeIfPresent([String].self, forKey: .validationArguments) ?? []
                runtimeDependencies = try values.decodeIfPresent([RuntimeDependency].self, forKey: .runtimeDependencies) ?? []
                hostIntegration = try values.decodeIfPresent(HostIntegration.self, forKey: .hostIntegration)
            }

            private enum CodingKeys: String, CodingKey {
                case languageID, languageIdentifier, launch, arguments, validationArguments, runtimeDependencies
                case hostIntegration
            }
        }
        /// Templates stay opaque to the host; only their presence matters here.
        struct ExecutionProvider: Decodable {
            let languageID: String
            let run: JSONPresence?
            let test: JSONPresence?
        }
        struct JSONPresence: Decodable {
            init(from decoder: Decoder) throws {}
        }

        let id: String
        let displayName: String
        let version: String
        let pluginAPIVersion: Int
        let vendor: Vendor
        let permissions: [String]
        let activationEvents: [String]
        let languages: [Language]
        let languageServers: [LanguageServer]
        let executionProviders: [ExecutionProvider]

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            displayName = try values.decode(String.self, forKey: .displayName)
            version = try values.decode(String.self, forKey: .version)
            pluginAPIVersion = try values.decode(Int.self, forKey: .pluginAPIVersion)
            vendor = try values.decode(Vendor.self, forKey: .vendor)
            permissions = try values.decodeIfPresent([String].self, forKey: .permissions) ?? []
            activationEvents = try values.decodeIfPresent([String].self, forKey: .activationEvents) ?? []
            languages = try values.decode([Language].self, forKey: .languages)
            languageServers = try values.decodeIfPresent([LanguageServer].self, forKey: .languageServers) ?? []
            executionProviders = try values.decodeIfPresent([ExecutionProvider].self, forKey: .executionProviders) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case id, displayName, version, pluginAPIVersion, vendor, permissions, activationEvents
            case languages, languageServers, executionProviders
        }
    }
}

/// Validates `plugin.json` contents through the shared contract implementation.
public protocol DeclarativePluginManifestValidating: Sendable {
    /// Throws `DeclarativePluginRejection` for a refused manifest.
    func validate(manifest: Data) throws -> DeclarativePluginDescriptor
}

/// Expands a declarative plugin's run and test templates. Implementations
/// throw `DeclarativePluginRejection`, translated with `runError` /
/// `testError(languageID:)` where an existing workflow error applies.
public protocol DeclarativeExecutionPlanning: Sendable {
    func runPlan(
        manifest: Data,
        languageID: String,
        request: LanguageRunExtensionRequest
    ) throws -> LanguageRunExtensionPlan

    func discoverTests(
        manifest: Data,
        languageID: String,
        request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem]

    func testPlan(
        manifest: Data,
        languageID: String,
        request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan
}

/// Expands a declarative language server's launch declaration. Implementations
/// throw `DeclarativePluginRejection`.
public protocol DeclarativeLanguageServerLaunchPlanning: Sendable {
    func languageServerLaunchPlan(
        manifest: Data,
        languageID: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan
}

/// Reads a launch runtime's version from its probe output and compares it
/// with the declared minimum. Implementations throw `DeclarativePluginRejection`.
public protocol LanguageServerRuntimeVersionChecking: Sendable {
    func checkRuntimeVersion(
        _ requirement: LanguageServerExecutableVersionRequirement,
        output: String
    ) throws -> LanguageServerRuntimeVersionCheck
}
