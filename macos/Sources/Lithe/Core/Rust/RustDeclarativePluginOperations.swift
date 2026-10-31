import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Typed `plugins.declarative.*` operations. Rust Core owns manifest
/// validation and template expansion for both products; this adapter only
/// translates payloads and outcomes.
struct RustDeclarativePluginOperations: DeclarativePluginManifestValidating, DeclarativeExecutionPlanning,
    DeclarativeLanguageServerLaunchPlanning, DeclarativePluginSettingsResolving, LanguageServerRuntimeVersionChecking,
    DeclarativeEditorContributionDecoding {
    let core: RustCoreBridge

    func validateNativeNodes(ui: PluginNativeUI, data: ToolingJSONValue) throws -> [PluginNativeUI.Node] {
        struct Payload: Encodable { let ui: PluginNativeUI; let data: ToolingJSONValue }
        struct Nodes: Decodable { let nodes: [PluginNativeUI.Node] }
        let outcome: Outcome<Nodes> = try execute("plugins.nativeUI.validateData", payload: Payload(ui: ui, data: data))
        return outcome.value.nodes
    }

    func validate(manifest: Data) throws -> DeclarativePluginDescriptor {
        let outcome: Outcome<ValidatedPlugin> = try execute(
            "plugins.declarative.validate",
            payload: ValidatePayload(
                manifest: try Self.json(manifest),
                hostCapabilities: PluginManifest.hostCapabilities
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try DeclarativePluginDescriptor(normalizedManifest: encoder.encode(outcome.value.plugin))
    }

    func runPlan(
        manifest: Data,
        languageID: String,
        request: LanguageRunExtensionRequest
    ) throws -> LanguageRunExtensionPlan {
        let outcome: Outcome<PlanResult> = try execute(
            "plugins.declarative.runPlan",
            payload: PlanPayload(
                manifest: try Self.json(manifest),
                languageID: languageID,
                request: RunRequest(relativeFilePath: request.relativeFilePath, arguments: request.arguments)
            )
        )
        return outcome.value.plan.launchPlan(environment: request.environment)
    }

    func discoverTests(
        manifest: Data,
        languageID: String,
        request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem] {
        let outcome: Outcome<DiscoveryResult> = try execute(
            "plugins.declarative.discoverTests",
            payload: PlanPayload(
                manifest: try Self.json(manifest),
                languageID: languageID,
                request: DiscoveryRequest(relativeProjectFilePaths: request.relativeProjectFilePaths)
            )
        )
        return try outcome.value.items.map { item in
            guard let kind = LanguageTestExtensionItemKind(rawValue: item.kind) else {
                throw DeclarativePluginRejection(
                    code: "plugin.manifest.invalid",
                    message: "Rust Core returned an unknown test item kind: \(item.kind)."
                )
            }
            return LanguageTestExtensionItem(
                id: item.id,
                label: item.label,
                kind: kind,
                relativeFilePath: item.relativeFilePath
            )
        }
    }

    func testPlan(
        manifest: Data,
        languageID: String,
        request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan {
        let scope: TestScope = switch request.scope {
        case .workspace:
            TestScope(kind: "workspace", relativeFilePath: nil, identifier: nil)
        case .file(let relativePath):
            TestScope(kind: "file", relativeFilePath: relativePath, identifier: nil)
        case .testCase(let identifier, let relativeFilePath):
            TestScope(kind: "testCase", relativeFilePath: relativeFilePath, identifier: identifier)
        }
        let outcome: Outcome<PlanResult> = try execute(
            "plugins.declarative.testPlan",
            payload: PlanPayload(
                manifest: try Self.json(manifest),
                languageID: languageID,
                request: TestRequest(scope: scope, relativeProjectFilePaths: request.relativeProjectFilePaths)
            )
        )
        let plan = outcome.value.plan
        return LanguageTestExtensionPlan(
            label: plan.label ?? languageID,
            frameworkID: plan.frameworkID,
            launchPlan: plan.launchPlan(environment: [:])
        )
    }

    func languageServerLaunchPlan(
        manifest: Data,
        languageID: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        try launchPlan(LaunchPlanPayload(
            manifest: try Self.json(manifest),
            languageID: languageID,
            buildSystemID: nil,
            request: LaunchRequest(request)
        ))
    }

    func buildProviderLaunchPlan(
        manifest: Data,
        buildSystemID: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        try launchPlan(LaunchPlanPayload(
            manifest: try Self.json(manifest),
            languageID: nil,
            buildSystemID: buildSystemID,
            request: LaunchRequest(request)
        ))
    }

    func vcsProviderLaunchPlan(
        manifest: Data,
        vcs: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        try launchPlan(LaunchPlanPayload(
            manifest: try Self.json(manifest),
            languageID: nil,
            buildSystemID: nil,
            vcsProviderID: vcs,
            request: LaunchRequest(request)
        ))
    }

    func backendLaunchPlan(
        manifest: Data,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        try launchPlan(LaunchPlanPayload(
            manifest: try Self.json(manifest),
            languageID: nil,
            buildSystemID: nil,
            backend: true,
            request: LaunchRequest(request)
        ))
    }

    func debugAdapterLaunchPlan(
        manifest: Data,
        adapterID: String,
        request: DeclarativeLanguageServerLaunchRequest
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        try launchPlan(LaunchPlanPayload(
            manifest: try Self.json(manifest),
            languageID: nil,
            buildSystemID: nil,
            debugAdapterID: adapterID,
            request: LaunchRequest(request)
        ))
    }

    func debugStartArguments(
        manifest: Data,
        adapterID: String,
        request: DeclarativeDebugStartRequest
    ) throws -> [String: ToolingJSONValue] {
        let outcome: Outcome<DebugStartArgumentsResult> = try execute(
            "debug.adapters.startArguments",
            payload: DebugStartArgumentsPayload(
                manifest: try Self.json(manifest),
                adapterID: adapterID,
                request: request.request.rawValue,
                facts: .init(
                    registration: .init(
                        generation: request.registrationGeneration,
                        currentGeneration: request.currentRegistrationGeneration
                    ),
                    target: .init(
                        kind: request.targetKind,
                        path: request.path,
                        processID: request.processID,
                        workingDirectory: request.workingDirectory,
                        executable: request.executable,
                        arguments: request.arguments, environment: request.environment
                    )
                )
            )
        )
        return outcome.value.arguments
    }

    func debugExecutablePlan(
        manifest: Data,
        adapterID: String,
        settings: [String: ToolingJSONValue],
        projectSettings: [String: ToolingJSONValue],
        workspace: String?,
        targetPath: String?
    ) throws -> DeclarativeDebugExecutablePlan? {
        let outcome: Outcome<DebugExecutablePlanResult> = try execute(
            "debug.adapters.executablePlan",
            payload: DebugExecutablePlanPayload(
                manifest: try Self.json(manifest),
                adapterID: adapterID,
                settings: settings,
                projectSettings: projectSettings,
                workspace: workspace,
                targetPath: targetPath
            )
        )
        guard let plan = outcome.value.plan else { return nil }
        return DeclarativeDebugExecutablePlan(
            settingID: plan.setting,
            configured: plan.configured.map {
                .init(path: $0.path, source: PluginSettingSource(rawValue: $0.source) ?? .default)
            },
            candidates: plan.candidates
        )
    }

    private func launchPlan(_ payload: LaunchPlanPayload) throws -> DeclarativeLanguageServerLaunchPlan {
        let outcome: Outcome<LaunchPlanResult> = try execute(
            "plugins.declarative.languageServerLaunchPlan",
            payload: payload
        )
        let plan = outcome.value.plan
        var result = DeclarativeLanguageServerLaunchPlan(
            arguments: plan.arguments,
            validationArguments: plan.validationArguments,
            initializationOptions: plan.initializationOptions,
            entryPath: plan.launch.entry,
            hostIntegration: plan.hostIntegration.map {
                .init(id: $0.id, resources: $0.resources.mapValues(\.paths))
            },
            packagedRuntimePath: plan.launch.packagedRuntime,
            executableVersionRequirement: plan.launch.versionRequirement,
            runtimeRequirements: plan.runtimeRequirements.map {
                .init(tool: $0.tool, minimumVersion: $0.minimumVersion)
            },
            requiredDirectories: try plan.requiredDirectories.map { name in
                guard let directory = DeclarativeLanguageServerLaunchPlan.RequiredDirectory(rawValue: name) else {
                    throw DeclarativePluginRejection(
                        code: "plugin.manifest.invalid",
                        message: "Rust Core returned an unknown launch directory: \(name)."
                    )
                }
                return directory
            },
            requiredPackagePaths: plan.requiredPackagePaths,
            executable: plan.launch.executable,
            buildProvider: plan.buildProvider.map {
                .init(
                    buildSystemID: $0.buildSystemID,
                    executesProjectCode: $0.executesProjectCode,
                    mayUseNetwork: $0.mayUseNetwork,
                    languageServer: $0.languageServer
                )
            }
        )
        result.workspaceConfiguration = plan.workspaceConfiguration
        result.vcsProvider = plan.vcsProvider.map {
            .init(
                vcs: $0.vcs,
                toolCommands: $0.tool?.commands ?? [],
                toolValidationArguments: $0.tool?.validationArguments ?? [],
                mayUseNetwork: $0.mayUseNetwork ?? false
            )
        }
        result.backend = plan.backend.map { .init(hostServices: $0.hostServices) }
        result.debugAdapter = plan.debugAdapter.map {
            .init(
                id: $0.id,
                providerID: $0.providerID,
                displayName: $0.displayName,
                adapterID: $0.adapterID,
                requests: $0.requests,
                languageIDs: $0.selectors.flatMap { $0.languageIDs ?? [] },
                transport: $0.transport,
                languageServerEndpoint: $0.endpoint.flatMap { endpoint in
                    guard let languageID = endpoint.languageID, let command = endpoint.command else {
                        return nil
                    }
                    return .init(languageID: languageID, command: command)
                }
            )
        }
        return result
    }

    func decodeGrammar(manifest: Data, languageID: String, grammar: String) throws -> ToolingJSONValue {
        struct Payload: Encodable { let manifest: ToolingJSONValue; let languageID: String; let grammar: String }
        struct Result: Decodable { let language: ToolingJSONValue }
        let outcome: Outcome<Result> = try execute(
            "plugins.declarative.decodeGrammar",
            payload: Payload(manifest: try Self.json(manifest), languageID: languageID, grammar: grammar)
        )
        return outcome.value.language
    }

    func decodeRunMarkers(
        manifest: Data, languageID: String, lineCount: Int, result: ToolingJSONValue
    ) throws -> [PluginRunMarker] {
        struct Payload: Encodable {
            let manifest: ToolingJSONValue; let languageID: String; let lineCount: Int; let result: ToolingJSONValue
        }
        struct Result: Decodable { let markers: [PluginRunMarker] }
        let outcome: Outcome<Result> = try execute(
            "plugins.declarative.decodeRunMarkers",
            payload: Payload(manifest: try Self.json(manifest), languageID: languageID, lineCount: lineCount, result: result)
        )
        return outcome.value.markers
    }

    func resolveSettings(
        manifest: Data,
        settings: [String: ToolingJSONValue],
        projectSettings: [String: ToolingJSONValue]
    ) throws -> [ResolvedPluginSetting] {
        let outcome: Outcome<ResolvedSettingsResult> = try execute(
            "plugins.declarative.resolveSettings",
            payload: SettingsPayload(
                manifest: try Self.json(manifest),
                settings: settings,
                projectSettings: projectSettings,
                languageID: nil
            )
        )
        return outcome.value.settings.map {
            ResolvedPluginSetting(id: $0.id, value: $0.value, source: PluginSettingSource(rawValue: $0.source) ?? .default)
        }
    }

    func workspaceConfiguration(
        manifest: Data,
        languageID: String,
        settings: [String: ToolingJSONValue],
        projectSettings: [String: ToolingJSONValue]
    ) throws -> ToolingJSONValue? {
        let outcome: Outcome<WorkspaceConfigurationResult> = try execute(
            "plugins.declarative.workspaceConfiguration",
            payload: SettingsPayload(
                manifest: try Self.json(manifest),
                settings: settings,
                projectSettings: projectSettings,
                languageID: languageID
            )
        )
        let configuration = outcome.value.configuration
        return configuration == .null ? nil : configuration
    }

    func checkRuntimeVersion(
        _ requirement: LanguageServerExecutableVersionRequirement,
        output: String
    ) throws -> LanguageServerRuntimeVersionCheck {
        let outcome: Outcome<VersionCheckResult> = try execute(
            "plugins.declarative.checkRuntimeVersion",
            payload: VersionCheckRequest(
                tool: requirement.tool,
                minimumVersion: requirement.minimumVersion,
                output: output
            )
        )
        return LanguageServerRuntimeVersionCheck(
            satisfied: outcome.value.check.satisfied,
            version: outcome.value.check.version
        )
    }

    private func execute<Payload: Encodable, Value: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Outcome<Value> {
        let outcome: Outcome<Value>
        do {
            outcome = try core.executeResult(command: command, payload: payload).get()
        } catch {
            throw DeclarativePluginRejection(
                code: "plugin.manifest.invalid",
                message: "Lithe could not evaluate the plugin declaration: \(error.localizedDescription)"
            )
        }
        if let rejection = outcome.error {
            throw DeclarativePluginRejection(
                code: rejection.code,
                message: rejection.message,
                field: rejection.field
            )
        }
        return outcome
    }

    private static func json(_ data: Data) throws -> ToolingJSONValue {
        do {
            return try JSONDecoder().decode(ToolingJSONValue.self, from: data)
        } catch {
            throw DeclarativePluginRejection(
                code: "plugin.manifest.invalid",
                message: "plugin.json is not valid JSON."
            )
        }
    }

    // MARK: Wire types

    private struct ValidatePayload: Encodable {
        let manifest: ToolingJSONValue
        let hostCapabilities: [String: [Int]]
    }

    private struct PlanPayload<Request: Encodable>: Encodable {
        let manifest: ToolingJSONValue
        let languageID: String
        let request: Request
    }

    private struct RunRequest: Encodable {
        let relativeFilePath: String
        let arguments: [String]
    }

    private struct DiscoveryRequest: Encodable {
        let relativeProjectFilePaths: [String]
    }

    private struct TestScope: Encodable {
        let kind: String
        let relativeFilePath: String?
        let identifier: String?
    }

    private struct TestRequest: Encodable {
        let scope: TestScope
        let relativeProjectFilePaths: [String]
    }

    private struct LaunchRequest: Encodable {
        let pluginDirectory: String
        let stateDirectory: String
        /// Omitted for a process bound to no workspace.
        let workspaceStateDirectory: String?
        let architecture: String
        let settings: [String: ToolingJSONValue]
        let projectSettings: [String: ToolingJSONValue]

        init(_ request: DeclarativeLanguageServerLaunchRequest) {
            pluginDirectory = request.pluginDirectory.path
            stateDirectory = request.stateDirectory.path
            workspaceStateDirectory = request.workspaceStateDirectory?.path
            architecture = request.architecture
            settings = request.settings
            projectSettings = request.projectSettings
        }
    }

    private struct LaunchPlan: Decodable {
        struct RuntimeRequirement: Decodable {
            let tool: String
            let minimumVersion: String?
        }

        struct Launch: Decodable {
            let kind: String?
            let path: String?
            let commands: [String]?
            let tool: String?
            let entry: String?
            let packagedRuntime: String?
            let minimumVersion: String?
            let versionArguments: [String]?

            var executable: DeclarativeLanguageServerLaunchPlan.Executable? {
                switch kind {
                case "packaged": path.map { .packaged($0) }
                case "systemCommand": commands.map { .systemCommand($0) }
                case "runtime": tool.map { .runtime($0) }
                default: nil
                }
            }

            var versionRequirement: LanguageServerExecutableVersionRequirement? {
                guard let tool, let minimumVersion, let versionArguments else { return nil }
                return LanguageServerExecutableVersionRequirement(
                    tool: tool,
                    minimumVersion: minimumVersion,
                    probeArguments: versionArguments
                )
            }
        }

        /// One package path or an ordered list of them.
        struct ResourcePaths: Decodable {
            let paths: [String]

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let path = try? container.decode(String.self) {
                    paths = [path]
                } else {
                    paths = try container.decode([String].self)
                }
            }
        }

        struct HostIntegration: Decodable {
            let id: String
            let resources: [String: ResourcePaths]
        }

        let launch: Launch
        let hostIntegration: HostIntegration?
        let arguments: [String]
        let validationArguments: [String]
        let initializationOptions: ToolingJSONValue?
        let workspaceConfiguration: ToolingJSONValue?
        let runtimeRequirements: [RuntimeRequirement]
        let requiredDirectories: [String]
        let requiredPackagePaths: [String]
        let buildProvider: BuildProvider?
        let vcsProvider: VcsProvider?
        let backend: Backend?
        let debugAdapter: DebugAdapter?

        struct DebugAdapter: Decodable {
            struct Selector: Decodable {
                let languageIDs: [String]?
            }

            let id: String
            let providerID: String
            let displayName: String
            let adapterID: String
            let requests: [String]
            let selectors: [Selector]
            let transport: String
            let endpoint: Endpoint?

            /// Only the fields of `tcpLanguageServer` are read; the other
            /// transports' endpoint fields stay with the Core.
            struct Endpoint: Decodable {
                let languageID: String?
                let command: String?
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(String.self, forKey: .id)
                providerID = try values.decode(String.self, forKey: .providerID)
                displayName = try values.decode(String.self, forKey: .displayName)
                adapterID = try values.decode(String.self, forKey: .adapterID)
                requests = try values.decode([String].self, forKey: .requests)
                selectors = try values.decodeIfPresent([Selector].self, forKey: .selectors) ?? []
                // Stdio when a plan carries none.
                transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? "stdio"
                endpoint = try values.decodeIfPresent(Endpoint.self, forKey: .endpoint)
            }

            private enum CodingKeys: String, CodingKey {
                case id, providerID, displayName, adapterID, requests, selectors, transport, endpoint
            }
        }

        struct Backend: Decodable {
            let hostServices: [String]
        }

        struct VcsProvider: Decodable {
            struct Tool: Decodable {
                let commands: [String]
                let validationArguments: [String]?
            }

            let vcs: String
            let tool: Tool?
            let mayUseNetwork: Bool?
        }

        struct BuildProvider: Decodable {
            let buildSystemID: String
            let executesProjectCode: Bool
            let mayUseNetwork: Bool
            let languageServer: String?
        }
    }

    private struct SettingsPayload: Encodable {
        let manifest: ToolingJSONValue
        let settings: [String: ToolingJSONValue]
        let projectSettings: [String: ToolingJSONValue]
        let languageID: String?
    }

    private struct ResolvedSettingsResult: Decodable {
        struct Setting: Decodable {
            let id: String
            let value: ToolingJSONValue
            let source: String
        }

        let settings: [Setting]
    }

    private struct WorkspaceConfigurationResult: Decodable {
        let configuration: ToolingJSONValue?
    }

    /// Names the process by exactly one of its language and its build system.
    private struct LaunchPlanPayload: Encodable {
        let manifest: ToolingJSONValue
        let languageID: String?
        let buildSystemID: String?
        var vcsProviderID: String? = nil
        var debugAdapterID: String? = nil
        /// Selects the plugin backend; omitted for every other process.
        var backend: Bool? = nil
        let request: LaunchRequest
    }

    private struct DebugStartArgumentsPayload: Encodable {
        struct Facts: Encodable {
            struct Registration: Encodable {
                let generation: Int
                let currentGeneration: Int
            }

            struct Target: Encodable {
                let kind: String
                let path: String?
                let processID: Int?
                let workingDirectory: String?
                let executable: String?
                let arguments: [String]?
                let environment: [String: String]?
            }

            let registration: Registration
            let target: Target
        }

        let manifest: ToolingJSONValue
        let adapterID: String
        let request: String
        let facts: Facts
    }

    private struct DebugStartArgumentsResult: Decodable {
        let arguments: [String: ToolingJSONValue]
    }

    private struct DebugExecutablePlanPayload: Encodable {
        let manifest: ToolingJSONValue
        let adapterID: String
        let settings: [String: ToolingJSONValue]
        let projectSettings: [String: ToolingJSONValue]
        let workspace: String?
        let targetPath: String?
    }

    private struct DebugExecutablePlanResult: Decodable {
        struct Plan: Decodable {
            struct Configured: Decodable {
                let path: String
                let source: String
            }

            let setting: String
            let configured: Configured?
            let candidates: [String]
        }

        /// Null when the adapter declares no executable lookup.
        let plan: Plan?
    }

    private struct LaunchPlanResult: Decodable {
        let plan: LaunchPlan
    }

    private struct VersionCheckRequest: Encodable {
        let tool: String
        let minimumVersion: String
        let output: String
    }

    private struct VersionCheckResult: Decodable {
        struct Check: Decodable {
            let satisfied: Bool
            let version: String?
        }

        let check: Check
    }

    private struct Rejection: Decodable {
        let code: String
        let message: String
        let field: String?
    }

    /// `{status: "ok", …}` with the operation's value at the top level, or
    /// `{status: "rejected", error}`.
    private struct Outcome<Value: Decodable>: Decodable {
        let error: Rejection?
        private let decodedValue: Value?

        var value: Value { decodedValue! }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decode(String.self, forKey: .status) == "rejected" {
                error = try container.decode(Rejection.self, forKey: .error)
                decodedValue = nil
            } else {
                error = nil
                decodedValue = try Value(from: decoder)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case status, error
        }
    }

    private struct ValidatedPlugin: Decodable {
        let plugin: ToolingJSONValue
    }

    private struct Executable: Decodable {
        let command: String?
        let toolchain: String?
    }

    private struct Plan: Decodable {
        let executable: Executable
        let arguments: [String]
        let workingDirectory: String
        let label: String?
        let frameworkID: String?

        func launchPlan(environment: [String: String]) -> LanguageRunExtensionPlan {
            LanguageRunExtensionPlan(
                executable: executable.toolchain.map { .toolchain($0) } ?? .command(executable.command ?? ""),
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
        }
    }

    private struct PlanResult: Decodable {
        let plan: Plan
    }

    private struct Item: Decodable {
        let id: String
        let label: String
        let kind: String
        let relativeFilePath: String?
    }

    private struct DiscoveryResult: Decodable {
        let items: [Item]
    }
}
