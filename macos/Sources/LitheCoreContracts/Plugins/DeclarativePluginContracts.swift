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
    }

    public let languageID: String
    public let languageIdentifier: String
    public let launch: Launch
    public let arguments: [String]
    public let validationArguments: [String]
    /// Runtimes the host discovers for the server, such as `node`.
    public let runtimeTools: [String]

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
        }
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

    public init(normalizedManifest: Data) throws {
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
                launch: server.launch.kind == "packaged"
                    ? .packaged(relativePath: server.launch.path ?? "")
                    : .systemCommand(server.launch.commands ?? []),
                arguments: server.arguments,
                validationArguments: server.validationArguments,
                runtimeTools: server.runtimeDependencies.map(\.tool)
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
        let executionByLanguage = Dictionary(uniqueKeysWithValues: executionProviders.map { ($0.languageID, $0) })
        var modules = languageServers.map { server in
            PluginModuleDeclaration(manifest: LanguageExtensionModuleManifests.languageServer(
                languageID: server.languageID,
                displayName: displayNames[server.languageID] ?? server.languageID
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
                    : nil
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
        }
        struct RuntimeDependency: Decodable {
            let tool: String
        }
        struct LanguageServer: Decodable {
            let languageID: String
            let languageIdentifier: String?
            let launch: Launch
            let arguments: [String]
            let validationArguments: [String]
            let runtimeDependencies: [RuntimeDependency]

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                languageID = try values.decode(String.self, forKey: .languageID)
                languageIdentifier = try values.decodeIfPresent(String.self, forKey: .languageIdentifier)
                launch = try values.decode(Launch.self, forKey: .launch)
                arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
                validationArguments = try values.decodeIfPresent([String].self, forKey: .validationArguments) ?? []
                runtimeDependencies = try values.decodeIfPresent([RuntimeDependency].self, forKey: .runtimeDependencies) ?? []
            }

            private enum CodingKeys: String, CodingKey {
                case languageID, languageIdentifier, launch, arguments, validationArguments, runtimeDependencies
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
