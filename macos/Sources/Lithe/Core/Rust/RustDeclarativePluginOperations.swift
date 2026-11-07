import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Typed `plugins.declarative.*` operations. Rust Core owns manifest
/// validation and template expansion for both products; this adapter only
/// translates payloads and outcomes.
struct RustDeclarativePluginOperations: DeclarativePluginManifestValidating, DeclarativeExecutionPlanning,
    DeclarativeLanguageServerLaunchPlanning, DeclarativePluginSettingsResolving, LanguageServerRuntimeVersionChecking,
    DeclarativeEditorContributionDecoding, PluginEditorActionDecoding, PluginContentDecoding,
    PluginEditorProviderDecoding {
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

    func decodeLaunch(
        manifest: Data,
        languageID: String,
        request: DeclarativeLanguageServerLaunchRequest,
        result: ToolingJSONValue
    ) throws -> DeclarativeLanguageServerLaunchPlan {
        let outcome: Outcome<LaunchPlanResult> = try execute(
            "plugins.languageServers.decodeLaunch",
            payload: DecodeLaunchPayload(
                manifest: try Self.json(manifest),
                languageID: languageID,
                request: LaunchRequest(request),
                result: result
            )
        )
        return try Self.launchPlan(from: outcome.value.plan)
    }

    func expiredLanguageServerStateNames(
        retention: DeclarativeLanguageServer.StateRetention,
        nowUnixSeconds: Int,
        entries: [LanguageServerStateEntry],
        activeNames: [String]
    ) throws -> [String] {
        // This command answers with its data only, without a status.
        let result: Result<StateRetentionResult, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "plugins.languageServers.stateRetention",
            payload: StateRetentionPayload(
                retention: .init(maxEntries: retention.maxEntries, maxAgeDays: retention.maxAgeDays),
                nowUnixSeconds: nowUnixSeconds,
                entries: entries.map {
                    .init(name: $0.name, lastModifiedUnixSeconds: $0.lastModifiedUnixSeconds)
                },
                activeNames: activeNames
            )
        )
        do {
            return try result.get().expiredNames
        } catch {
            throw DeclarativePluginRejection(
                code: "plugin.launch.invalidRequest",
                message: "Lithe could not select the expired language server state: \(error.localizedDescription)"
            )
        }
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
                        host: request.host, port: request.port,
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
        return try Self.launchPlan(from: outcome.value.plan)
    }

    /// Maps Core's wire plan, from either step of a launch, to the plan the
    /// host works with.
    private static func launchPlan(from plan: LaunchPlan) throws -> DeclarativeLanguageServerLaunchPlan {
        var result = DeclarativeLanguageServerLaunchPlan(
            arguments: plan.arguments,
            validationArguments: plan.validationArguments,
            initializationOptions: plan.initializationOptions,
            // A tool launch carries an absolute entry, which `toolLaunch` holds.
            entryPath: plan.launch.kind == "tool" ? nil : plan.launch.entry,
            hostIntegration: plan.hostIntegration.map {
                .init(id: $0.id, resources: $0.resources.mapValues(\.paths))
            },
            packagedRuntimePath: plan.launch.packagedRuntime,
            executableVersionRequirement: plan.launch.versionRequirement,
            runtimeRequirements: plan.runtimeRequirements.map {
                .init(tool: $0.tool, minimumVersion: $0.minimumVersion, resolvesThroughDefinition: $0.kind == "tool")
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
        // The second step of a backend launch also says `tool`, but it names a
        // resolved program, which `resolvedLaunch` carries instead.
        result.toolLaunch = plan.writablePaths == nil ? plan.launch.toolLaunch : nil
        result.backendResolution = plan.backendResolution
        result.resolvedLaunch = plan.resolvedLaunch
        result.sessionPolicy = plan.sessionPolicy
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

    func decodeEditorActions(
        kind: String, value: ToolingJSONValue, text: String = "", host: PluginEditorHostOptions
    ) throws -> ToolingJSONValue {
        struct Payload: Encodable {
            let kind: String
            let value: ToolingJSONValue
            let text: String
            let version = 2
            let icons: [String]
            let sourceBytes: Int
        }
        let result: ToolingJSONValue = try core.executeResult(
            command: "plugins.editorActions.decode",
            payload: Payload(kind: kind, value: value, text: text, icons: host.actionIcons, sourceBytes: host.actionSourceBytes)
        ).get()
        return result
    }

    func decodeContent(_ answer: ToolingJSONValue) throws -> String {
        struct Payload: Encodable { let result: ToolingJSONValue }
        struct Decoded: Decodable { let content: String }
        // This command answers with its data only, without a status.
        let decoded: Decoded = try core.executeResult(
            command: "plugins.contentProviders.decode", payload: Payload(result: answer)
        ).get()
        return decoded.content
    }

    func decodeEditorProviderRegistration(value: ToolingJSONValue, types: [String]) throws -> ToolingJSONValue {
        struct Payload: Encodable { let kind = "registration"; let value: ToolingJSONValue; let types: [String] }
        let outcome: Result<ToolingJSONValue, RustCoreBridge.CoreCallError> = core.executeResult(
            command: "plugins.editorProviders.decode", payload: Payload(value: value, types: types))
        switch outcome {
        case .success(let result): return result
        case .failure(let error):
            // Core reports a type the host does not route as notSupported
            // with `providers.<type>`; every other failure is malformed input.
            if error.code == "not_supported", let option = error.details, option.hasPrefix("providers.") {
                throw PluginEditorProviderUnsupported(option: option)
            }
            throw error
        }
    }

    func decodeEditorProviderResult(
        type: String, value: ToolingJSONValue, legend: ToolingJSONValue?
    ) throws -> ToolingJSONValue {
        struct Payload: Encodable {
            let kind = "result"
            let type: String
            let value: ToolingJSONValue
            let legend: ToolingJSONValue?
        }
        let result: ToolingJSONValue = try core.executeResult(
            command: "plugins.editorProviders.decode", payload: Payload(type: type, value: value, legend: legend)
        ).get()
        return result
    }

    func mergeEditorDefinitions(
        documentURI: String, line: Int, character: Int, server: [ToolingJSONValue], plugin: [ToolingJSONValue]
    ) throws -> (server: [Int], plugin: [Int]) {
        struct Position: Encodable { let line: Int; let character: Int }
        struct Value: Encodable {
            let documentUri: String
            let position: Position
            let server: [ToolingJSONValue]
            let plugin: [ToolingJSONValue]
        }
        struct Payload: Encodable { let kind = "mergeDefinitions"; let value: Value }
        struct Kept: Decodable { let server: [Int]; let plugin: [Int] }
        let kept: Kept = try core.executeResult(
            command: "plugins.editorProviders.decode",
            payload: Payload(value: Value(
                documentUri: documentURI, position: Position(line: line, character: character),
                server: server, plugin: plugin))
        ).get()
        return (kept.server, kept.plugin)
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
        let logDirectory: String?
        /// Omitted unless the plugin backend resolves the launch.
        let temporaryDirectory: String?
        let pluginDirectory: String
        let stateDirectory: String
        /// Omitted for a process bound to no workspace.
        let workspaceStateDirectory: String?
        let architecture: String
        let settings: [String: ToolingJSONValue]
        let projectSettings: [String: ToolingJSONValue]

        init(_ request: DeclarativeLanguageServerLaunchRequest) {
            logDirectory = request.logDirectory?.path
            temporaryDirectory = request.temporaryDirectory?.path
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
            /// `tool` when the host resolves it through a tool definition.
            let kind: String?
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
            /// `tool` launches: values for `${runtimeArguments}`.
            let runtimeArguments: [String]?
            /// `backend` launches: the function to call and its timeout.
            let function: String?
            let timeoutMilliseconds: Int?

            var executable: DeclarativeLanguageServerLaunchPlan.Executable? {
                switch kind {
                case "packaged": path.map { .packaged($0) }
                case "systemCommand": commands.map { .systemCommand($0) }
                case "runtime": tool.map { .runtime($0) }
                default: nil
                }
            }

            /// A launch that names a tool definition, which `executable` leaves out.
            var toolLaunch: DeclarativeLanguageServerLaunchPlan.ToolLaunch? {
                guard kind == "tool", let tool, let entry else { return nil }
                return .init(
                    tool: tool,
                    entry: entry,
                    runtimeArguments: runtimeArguments ?? [],
                    minimumVersion: minimumVersion,
                    packagedRuntime: packagedRuntime
                )
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
        /// First step of a backend-resolved launch.
        let resolveParams: [String: ToolingJSONValue]?
        /// Second step of a backend-resolved launch.
        let environment: [String: String]?
        let writablePaths: [String]?
        let sessionPolicy: ToolingJSONValue?

        /// The question of the first step, when the plan asks one.
        var backendResolution: DeclarativeLanguageServerLaunchPlan.BackendResolution? {
            guard launch.kind == "backend", let function = launch.function, let resolveParams else { return nil }
            return .init(
                function: function,
                timeoutMilliseconds: launch.timeoutMilliseconds ?? 30_000,
                resolveParams: resolveParams
            )
        }

        /// The answer the second step decoded, when the plan holds one. Only
        /// a decoded answer carries `writablePaths`, which tells it apart
        /// from the ordinary plan of a packaged server.
        var resolvedLaunch: DeclarativeLanguageServerLaunchPlan.ResolvedLaunch? {
            guard let writablePaths else { return nil }
            let program: DeclarativeLanguageServerLaunchPlan.ResolvedLaunch.Program
            switch (launch.kind, launch.path, launch.tool) {
            case ("packaged", let path?, _): program = .packaged(path)
            case ("tool", _, let tool?): program = .tool(tool)
            default: return nil
            }
            return .init(program: program, environment: environment ?? [:], writablePaths: writablePaths)
        }

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

    private struct DecodeLaunchPayload: Encodable {
        let manifest: ToolingJSONValue
        let languageID: String
        let request: LaunchRequest
        let result: ToolingJSONValue
    }

    private struct StateRetentionPayload: Encodable {
        struct Retention: Encodable {
            let maxEntries: Int
            let maxAgeDays: Int
        }

        struct Entry: Encodable {
            let name: String
            let lastModifiedUnixSeconds: Int
        }

        let retention: Retention
        let nowUnixSeconds: Int
        let entries: [Entry]
        let activeNames: [String]
    }

    private struct StateRetentionResult: Decodable {
        let expiredNames: [String]
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
                let host: String?
                let port: UInt16?
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
