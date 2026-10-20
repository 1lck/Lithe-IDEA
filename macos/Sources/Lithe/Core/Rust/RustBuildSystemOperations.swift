import Foundation
import LitheCoreContracts

/// Typed `build.*` operations. Rust Core owns detection, command expansion,
/// and every decoder for both products; this adapter only translates
/// payloads and outcomes.
struct RustBuildSystemOperations: BuildSystemPlanning {
    let core: RustCoreBridge

    func detect(
        workspaceURL: URL,
        sources: [BuildSystemPluginSource],
        options: [String: [String: ToolingJSONValue]]
    ) throws -> BuildDetection {
        let outcome: Outcome<DetectionResult> = try execute(
            "build.detect",
            payload: DetectPayload(
                workspaceRoot: workspaceURL.path,
                plugins: try sources.map { DetectPayload.Plugin(manifest: try Self.json($0.manifest)) },
                options: options
            )
        )
        return outcome.value.detection
    }

    func languageImport(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        options: [String: ToolingJSONValue],
        executableURL: URL?
    ) throws -> BuildLanguageImport? {
        let outcome: Outcome<LanguageImportResult> = try execute(
            "build.languageImport",
            target: target,
            request: LanguageImportRequest(
                workspaceRoot: workspaceURL.path, root: root, options: options,
                executablePath: executableURL?.path
            )
        )
        return outcome.value.languageImport
    }

    func invocationPlan(_ target: BuildSystemTarget, root: String) throws -> BuildInvocation {
        let outcome: Outcome<InvocationResult> = try execute(
            "build.invocationPlan",
            target: target,
            request: InvocationRequest(root: root, platform: "macos")
        )
        return try outcome.value.invocation.invocation()
    }

    func checkToolVersion(_ target: BuildSystemTarget, runtime: String?, output: String) throws -> BuildVersionCheck {
        let outcome: Outcome<VersionResult> = try execute(
            "build.checkToolVersion",
            target: target,
            request: VersionRequest(runtime: runtime, output: output)
        )
        return outcome.value.version
    }

    func resolveOptions(
        _ target: BuildSystemTarget,
        options: [String: ToolingJSONValue],
        modelValues: [String: [String]]?
    ) throws -> BuildOptionsResolution {
        let outcome: Outcome<OptionsResult> = try execute(
            "build.resolveOptions",
            target: target,
            request: OptionsRequest(options: options, modelValues: modelValues)
        )
        return outcome.value.options
    }

    func modelPlan(_ target: BuildSystemTarget, context: BuildPlanContext, outputFile: URL?) throws -> BuildOutputPlan {
        let outcome: Outcome<PlanResult> = try execute(
            "build.modelPlan",
            target: target,
            request: OutputRequest(context: context, project: nil, outputFile: outputFile)
        )
        return try outcome.value.plan.outputPlan()
    }

    func taskPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTaskRequest) throws
        -> BuildProcessPlan {
        let outcome: Outcome<PlanResult> = try execute(
            "build.taskPlan",
            target: target,
            request: TaskRequest(context: context, request: request)
        )
        return try outcome.value.plan.processPlan()
    }

    func testPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTestRequest) throws
        -> BuildTestPlan {
        let outcome: Outcome<PlanResult> = try execute(
            "build.testPlan",
            target: target,
            request: TestRequest(context: context, request: request)
        )
        let plan = outcome.value.plan
        return BuildTestPlan(process: try plan.processPlan(), results: plan.results?.results)
    }

    func dependencyPlan(
        _ target: BuildSystemTarget,
        context: BuildPlanContext,
        project: BuildSelection?,
        outputFile: URL?
    ) throws -> BuildOutputPlan {
        let outcome: Outcome<PlanResult> = try execute(
            "build.dependencyPlan",
            target: target,
            request: OutputRequest(context: context, project: project, outputFile: outputFile)
        )
        return try outcome.value.plan.outputPlan()
    }

    func decodeModel(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        output: BuildCommandOutput,
        options: [String: ToolingJSONValue]
    ) throws -> BuildModel {
        let outcome: Outcome<ModelResult> = try execute(
            "build.decodeModel",
            target: target,
            request: DecodeModelRequest(
                workspaceRoot: workspaceURL.path,
                root: root,
                output: output.text,
                outputFile: output.filePath,
                result: output.providerResult,
                options: options
            )
        )
        return outcome.value.model
    }

    func decodeTestResults(_ target: BuildSystemTarget, request: BuildTestResultsRequest) throws -> BuildTestResults {
        let outcome: Outcome<TestResultsResult> = try execute(
            "build.decodeTestResults",
            target: target,
            request: DecodeTestResultsRequest(
                workspaceRoot: request.workspaceURL.path,
                root: request.root,
                project: request.project,
                projects: request.projects,
                output: request.output,
                notBeforeMillis: request.notBefore.map { UInt64(max(0, $0.timeIntervalSince1970 * 1000)) },
                suite: request.suite
            )
        )
        return outcome.value.results
    }

    func decodeDiagnostics(_ target: BuildSystemTarget, workspaceURL: URL, root: String, output: String) throws
        -> [BuildDiagnostic] {
        let outcome: Outcome<DiagnosticsResult> = try execute(
            "build.decodeDiagnostics",
            target: target,
            request: DecodeDiagnosticsRequest(workspaceRoot: workspaceURL.path, root: root, output: output)
        )
        return outcome.value.diagnostics
    }

    func decodeDependencies(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        project: String?,
        output: BuildCommandOutput
    ) throws -> BuildDependencyTree {
        let outcome: Outcome<DependenciesResult> = try execute(
            "build.decodeDependencies",
            target: target,
            request: DecodeDependenciesRequest(
                workspaceRoot: workspaceURL.path,
                root: root,
                project: project,
                output: output.text,
                outputFile: output.filePath,
                result: output.providerResult
            )
        )
        return outcome.value.dependencies
    }

    func syncFingerprint(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        projects: [String],
        options: [String: ToolingJSONValue]
    ) throws -> BuildSyncState {
        let outcome: Outcome<SyncResult> = try execute(
            "build.syncFingerprint",
            target: target,
            request: SyncRequest(workspaceRoot: workspaceURL.path, root: root, projects: projects, options: options)
        )
        return outcome.value.sync
    }

    private func execute<Request: Encodable, Value: Decodable>(
        _ command: String,
        target: BuildSystemTarget,
        request: Request
    ) throws -> Outcome<Value> {
        try execute(
            command,
            payload: BuildPayload(
                manifest: try Self.json(target.manifest),
                buildSystemID: target.buildSystemID,
                request: request
            )
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
                code: "plugin.build.unavailable",
                message: "Lithe could not evaluate the build system: \(error.localizedDescription)"
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

    private struct DetectPayload: Encodable {
        struct Plugin: Encodable {
            let manifest: ToolingJSONValue
        }

        let workspaceRoot: String
        let plugins: [Plugin]
        let options: [String: [String: ToolingJSONValue]]
    }

    private struct BuildPayload<Request: Encodable>: Encodable {
        let manifest: ToolingJSONValue
        let buildSystemID: String
        let request: Request
    }

    private struct LanguageImportRequest: Encodable {
        let workspaceRoot: String
        let root: String
        let options: [String: ToolingJSONValue]
        let executablePath: String?
    }

    private struct LanguageImportResult: Decodable {
        let languageImport: BuildLanguageImport?
    }

    private struct InvocationRequest: Encodable {
        let root: String
        let platform: String
    }

    private struct VersionRequest: Encodable {
        let runtime: String?
        let output: String
    }

    private struct OptionsRequest: Encodable {
        let options: [String: ToolingJSONValue]
        let modelValues: [String: [String]]?
    }

    /// `PlanBase` is flattened into each plan request.
    private struct OutputRequest: Encodable {
        let root: String
        let options: [String: ToolingJSONValue]
        let pluginDirectory: String?
        let workspaceStateDirectory: String?
        let project: BuildSelection?
        let outputFile: String?

        init(context: BuildPlanContext, project: BuildSelection?, outputFile: URL?) {
            root = context.root
            options = context.options
            pluginDirectory = context.pluginDirectory?.path
            workspaceStateDirectory = context.workspaceStateDirectory?.path
            self.project = project
            self.outputFile = outputFile?.path
        }
    }

    private struct TaskRequest: Encodable {
        let root: String
        let options: [String: ToolingJSONValue]
        let pluginDirectory: String?
        let workspaceStateDirectory: String?
        let task: String
        let project: BuildSelection?
        let target: BuildSelection?
        let modelTask: BuildSelection?
        let userArguments: [String]

        init(context: BuildPlanContext, request: BuildTaskRequest) {
            root = context.root
            options = context.options
            pluginDirectory = context.pluginDirectory?.path
            workspaceStateDirectory = context.workspaceStateDirectory?.path
            task = request.task
            project = request.project
            target = request.target
            modelTask = request.modelTask
            userArguments = request.userArguments
        }
    }

    private struct TestRequest: Encodable {
        let root: String
        let options: [String: ToolingJSONValue]
        let pluginDirectory: String?
        let workspaceStateDirectory: String?
        let project: BuildSelection?
        let target: BuildSelection?
        let suite: String?
        let `case`: String?
        let userArguments: [String]
        let projects: [String]

        init(context: BuildPlanContext, request: BuildTestRequest) {
            root = context.root
            options = context.options
            pluginDirectory = context.pluginDirectory?.path
            workspaceStateDirectory = context.workspaceStateDirectory?.path
            project = request.project
            target = request.target
            suite = request.suite
            `case` = request.testCase
            userArguments = request.userArguments
            projects = request.projects
        }
    }

    private struct DecodeModelRequest: Encodable {
        let workspaceRoot: String
        let root: String
        let output: String?
        let outputFile: String?
        let result: ToolingJSONValue?
        let options: [String: ToolingJSONValue]
    }

    private struct DecodeTestResultsRequest: Encodable {
        let workspaceRoot: String
        let root: String
        let project: String?
        let projects: [String]
        let output: String
        let notBeforeMillis: UInt64?
        let suite: String?
    }

    private struct DecodeDiagnosticsRequest: Encodable {
        let workspaceRoot: String
        let root: String
        let output: String
    }

    private struct DecodeDependenciesRequest: Encodable {
        let workspaceRoot: String
        let root: String
        let project: String?
        let output: String?
        let outputFile: String?
        let result: ToolingJSONValue?
    }

    private struct SyncRequest: Encodable {
        let workspaceRoot: String
        let root: String
        let projects: [String]
        let options: [String: ToolingJSONValue]
    }

    private struct DetectionResult: Decodable {
        let detection: BuildDetection
    }

    private struct InvocationResult: Decodable {
        let invocation: WireInvocation
    }

    private struct VersionResult: Decodable {
        let version: BuildVersionCheck
    }

    private struct OptionsResult: Decodable {
        let options: BuildOptionsResolution
    }

    private struct PlanResult: Decodable {
        let plan: WirePlan
    }

    private struct ModelResult: Decodable {
        let model: BuildModel
    }

    private struct TestResultsResult: Decodable {
        let results: BuildTestResults
    }

    private struct DiagnosticsResult: Decodable {
        let diagnostics: [BuildDiagnostic]
    }

    private struct DependenciesResult: Decodable {
        let dependencies: BuildDependencyTree
    }

    private struct SyncResult: Decodable {
        let sync: BuildSyncState
    }

    private struct WireProbe: Decodable {
        let arguments: [String]
    }

    private struct WireExecutable: Decodable {
        let kind: String
        let path: String?
        let requires: [String]?
        let variable: String?
        let command: String?
        let runtime: String?

        func executable() throws -> BuildInvocation.Executable {
            switch (kind, path, variable, command, runtime) {
            case ("projectFile", let path?, _, _, _):
                return .projectFile(path: path, requires: requires ?? [])
            case ("environment", let path?, let variable?, _, _):
                return .environment(variable: variable, path: path)
            case ("command", _, _, let command?, _):
                return .command(command)
            case ("runtime", _, _, _, let runtime?):
                return .runtime(runtime)
            default:
                throw DeclarativePluginRejection(
                    code: "plugin.build.unavailable",
                    message: "Rust Core returned an unknown executable kind: \(kind)."
                )
            }
        }
    }

    private struct WireRuntime: Decodable {
        let id: String
        let displayName: String?
        let hostManaged: Bool
        let minimumVersion: String?
        let executables: [WireExecutable]
        let version: WireProbe?
    }

    private struct WireInvocation: Decodable {
        let executables: [WireExecutable]
        let environmentInputs: [String]
        let runtimeDependencies: [WireRuntime]
        let version: WireProbe?
        let minimumVersion: String?

        func invocation() throws -> BuildInvocation {
            BuildInvocation(
                executables: try executables.map { try $0.executable() },
                environmentInputs: environmentInputs,
                runtimeDependencies: try runtimeDependencies.map { runtime in
                    BuildInvocation.RuntimeDependency(
                        id: runtime.id,
                        displayName: runtime.displayName,
                        hostManaged: runtime.hostManaged,
                        minimumVersion: runtime.minimumVersion,
                        executables: try runtime.executables.map { try $0.executable() },
                        versionArguments: runtime.version?.arguments
                    )
                },
                versionArguments: version?.arguments,
                minimumVersion: minimumVersion
            )
        }
    }

    /// `null`, `{decoder, reports}`, or `{decoder: "hostIntegration"}`.
    private struct WireResults: Decodable {
        let decoder: String
        let reports: [String]?

        var results: BuildTestPlan.Results {
            decoder == "hostIntegration"
                ? .hostIntegration
                : .reports(decoder: decoder, patterns: reports ?? [])
        }
    }

    private struct WireProvider: Decodable {
        let method: String
        let params: ToolingJSONValue
    }

    /// A process plan, or the provider form of a model or dependency plan.
    private struct WirePlan: Decodable {
        let arguments: [String]?
        let environment: [String: String]?
        let workingDirectory: String?
        let execution: BuildExecution?
        let optionFingerprint: String
        let output: String?
        let executesProjectCode: Bool?
        let mayUseNetwork: Bool?
        let provider: WireProvider?
        let results: WireResults?

        func processPlan() throws -> BuildProcessPlan {
            guard let arguments, let workingDirectory else {
                throw DeclarativePluginRejection(
                    code: "plugin.build.unavailable",
                    message: "Rust Core returned a plan without a command."
                )
            }
            return BuildProcessPlan(
                arguments: arguments,
                environment: environment ?? [:],
                workingDirectory: workingDirectory,
                execution: execution ?? .task,
                optionFingerprint: optionFingerprint,
                output: output.flatMap(BuildProcessPlan.Output.init(rawValue:)),
                executesProjectCode: executesProjectCode ?? false,
                mayUseNetwork: mayUseNetwork ?? false
            )
        }

        func outputPlan() throws -> BuildOutputPlan {
            if let provider {
                return .provider(BuildProviderRequest(
                    method: provider.method,
                    params: provider.params,
                    optionFingerprint: optionFingerprint,
                    executesProjectCode: executesProjectCode ?? false,
                    mayUseNetwork: mayUseNetwork ?? false
                ))
            }
            return .process(try processPlan())
        }
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
}

private extension BuildCommandOutput {
    var text: String? {
        if case .stdout(let text) = self { return text }
        return nil
    }

    var filePath: String? {
        if case .outputFile(let url) = self { return url.path }
        return nil
    }

    var providerResult: ToolingJSONValue? {
        if case .providerResult(let result) = self { return result }
        return nil
    }
}
