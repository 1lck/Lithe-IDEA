import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Typed `plugins.declarative.*` operations. Rust Core owns manifest
/// validation and template expansion for both products; this adapter only
/// translates payloads and outcomes.
struct RustDeclarativePluginOperations: DeclarativePluginManifestValidating, DeclarativeExecutionPlanning,
    DeclarativeLanguageServerLaunchPlanning, LanguageServerRuntimeVersionChecking {
    let core: RustCoreBridge

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

    private func launchPlan(_ payload: LaunchPlanPayload) throws -> DeclarativeLanguageServerLaunchPlan {
        let outcome: Outcome<LaunchPlanResult> = try execute(
            "plugins.declarative.languageServerLaunchPlan",
            payload: payload
        )
        let plan = outcome.value.plan
        return DeclarativeLanguageServerLaunchPlan(
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
        let workspaceStateDirectory: String
        let architecture: String
        let settings: [String: ToolingJSONValue]

        init(_ request: DeclarativeLanguageServerLaunchRequest) {
            pluginDirectory = request.pluginDirectory.path
            stateDirectory = request.stateDirectory.path
            workspaceStateDirectory = request.workspaceStateDirectory.path
            architecture = request.architecture
            settings = request.settings
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
        let runtimeRequirements: [RuntimeRequirement]
        let requiredDirectories: [String]
        let requiredPackagePaths: [String]
        let buildProvider: BuildProvider?

        struct BuildProvider: Decodable {
            let buildSystemID: String
            let executesProjectCode: Bool
            let mayUseNetwork: Bool
            let languageServer: String?
        }
    }

    /// Names the process by exactly one of its language and its build system.
    private struct LaunchPlanPayload: Encodable {
        let manifest: ToolingJSONValue
        let languageID: String?
        let buildSystemID: String?
        let request: LaunchRequest
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
