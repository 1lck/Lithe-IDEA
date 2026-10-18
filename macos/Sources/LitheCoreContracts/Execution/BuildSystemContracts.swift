import Foundation

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

// MARK: Declarations

/// Where a task or test runs: the whole instance, one project, or one target.
public enum BuildScope: String, Codable, Hashable, Sendable {
    case workspace, project, target
}

/// Tool-window grouping of a task. Unknown groups from a newer Core read as
/// `other`.
public enum BuildTaskGroup: String, Hashable, Sendable, CaseIterable, Decodable {
    case lifecycle, build, test, run, verification, documentation, other

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = BuildTaskGroup(rawValue: value) ?? .other
    }
}

/// How a task's process behaves: it finishes, it is an application, or it
/// keeps serving until stopped.
public enum BuildExecution: String, Codable, Hashable, Sendable {
    case application, service, task

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = BuildExecution(rawValue: value) ?? .task
    }
}

/// What a plugin's build system offers, read from the normalized manifest.
/// Command templates stay opaque: Rust Core expands them.
public struct DeclarativeBuildSystem: Equatable, Sendable {
    public struct Task: Equatable, Identifiable, Sendable {
        public let id: String
        public let displayName: String
        public let group: BuildTaskGroup
        public let scopes: [BuildScope]
        /// A template that model tasks run through; it is never listed alone.
        public let fromModel: Bool
        public let targetTags: [String]
        public let requiresUserArguments: Bool
        public let description: String?

        public init(
            id: String, displayName: String, group: BuildTaskGroup, scopes: [BuildScope],
            fromModel: Bool, targetTags: [String], requiresUserArguments: Bool, description: String?
        ) {
            self.id = id; self.displayName = displayName; self.group = group; self.scopes = scopes
            self.fromModel = fromModel; self.targetTags = targetTags
            self.requiresUserArguments = requiresUserArguments; self.description = description
        }
    }

    /// Where the model comes from. `static` and `hostIntegration` models
    /// arrive with detection and never start a process.
    public enum ModelSource: String, Equatable, Sendable {
        case `static`, command, hostIntegration, provider
    }

    public let id: String
    public let displayName: String
    public let modelSource: ModelSource?
    public let tasks: [Task]
    /// Empty when the build system declares no test command.
    public let testScopes: [BuildScope]
    /// Tags a target must carry to run its tests.
    public let testTargetTags: [String]
    /// Empty when the build system lists no dependencies.
    public let dependencyScopes: [BuildScope]

    public init(
        id: String, displayName: String, modelSource: ModelSource?, tasks: [Task],
        testScopes: [BuildScope], testTargetTags: [String] = [], dependencyScopes: [BuildScope]
    ) {
        self.id = id; self.displayName = displayName; self.modelSource = modelSource; self.tasks = tasks
        self.testScopes = testScopes; self.testTargetTags = testTargetTags; self.dependencyScopes = dependencyScopes
    }
}

/// An enabled plugin's build systems, as the host hands them to Rust Core.
package struct BuildSystemPluginSource: Equatable, Sendable {
    package let pluginID: String
    /// Normalized manifest from `plugins.declarative.validate`.
    package let manifest: Data
    /// Installed package directory, read-only, for `${pluginDir}`.
    package let packageURL: URL
    package let buildSystems: [DeclarativeBuildSystem]

    package init(pluginID: String, manifest: Data, packageURL: URL, buildSystems: [DeclarativeBuildSystem]) {
        self.pluginID = pluginID; self.manifest = manifest; self.packageURL = packageURL
        self.buildSystems = buildSystems
    }
}

/// One build system of one plugin, addressed in every `build.*` command.
package struct BuildSystemTarget: Equatable, Sendable {
    package let manifest: Data
    package let buildSystemID: String

    package init(manifest: Data, buildSystemID: String) {
        self.manifest = manifest; self.buildSystemID = buildSystemID
    }
}

// MARK: Detection and model

/// A refusal Rust Core reported inside an otherwise successful result.
package struct BuildFailure: Equatable, Sendable, Decodable {
    package let code: String
    package let message: String
}

/// One build-system instance Core found in a workspace.
package struct BuildSystemInstance: Equatable, Identifiable, Sendable, Decodable {
    /// `<buildSystemID>:<root>`.
    package let id: String
    package let pluginID: String
    package let buildSystemID: String
    package let displayName: String
    /// Workspace-relative instance root.
    package let root: String
    package let markers: [String]
    package let modelSource: DeclarativeBuildSystem.ModelSource?
    package let optionFingerprint: String
    /// Present for `static` and `hostIntegration` models.
    package let model: BuildModel?
    package let modelError: BuildFailure?

    package init(
        id: String, pluginID: String, buildSystemID: String, displayName: String, root: String,
        markers: [String], modelSource: DeclarativeBuildSystem.ModelSource?, optionFingerprint: String,
        model: BuildModel?, modelError: BuildFailure?
    ) {
        self.id = id; self.pluginID = pluginID; self.buildSystemID = buildSystemID
        self.displayName = displayName; self.root = root; self.markers = markers
        self.modelSource = modelSource; self.optionFingerprint = optionFingerprint
        self.model = model; self.modelError = modelError
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        pluginID = try values.decode(String.self, forKey: .pluginID)
        buildSystemID = try values.decode(String.self, forKey: .buildSystemID)
        displayName = try values.decode(String.self, forKey: .displayName)
        root = try values.decode(String.self, forKey: .root)
        markers = try values.decodeIfPresent([String].self, forKey: .markers) ?? []
        modelSource = try values.decodeIfPresent(String.self, forKey: .modelSource)
            .flatMap(DeclarativeBuildSystem.ModelSource.init(rawValue:))
        optionFingerprint = try values.decode(String.self, forKey: .optionFingerprint)
        model = try values.decodeIfPresent(BuildModel.self, forKey: .model)
        modelError = try values.decodeIfPresent(BuildFailure.self, forKey: .modelError)
    }

    private enum CodingKeys: String, CodingKey {
        case id, pluginID, buildSystemID, displayName, root, markers, modelSource, optionFingerprint
        case model, modelError
    }
}

package struct BuildDetection: Equatable, Sendable, Decodable {
    /// A manifest Core refused; `index` is its position in the request.
    package struct Rejected: Equatable, Sendable, Decodable {
        package let index: Int
        package let error: BuildFailure
    }
    /// A build-system ID another plugin answers for.
    package struct Shadowed: Equatable, Sendable, Decodable {
        package let pluginID: String
        package let buildSystemID: String
        package let by: String
    }

    package let instances: [BuildSystemInstance]
    package let rejected: [Rejected]
    package let shadowed: [Shadowed]

    package init(instances: [BuildSystemInstance], rejected: [Rejected] = [], shadowed: [Shadowed] = []) {
        self.instances = instances; self.rejected = rejected; self.shadowed = shadowed
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        instances = try values.decodeIfPresent([BuildSystemInstance].self, forKey: .instances) ?? []
        rejected = try values.decodeIfPresent([Rejected].self, forKey: .rejected) ?? []
        shadowed = try values.decodeIfPresent([Shadowed].self, forKey: .shadowed) ?? []
    }

    private enum CodingKeys: String, CodingKey { case instances, rejected, shadowed }
}

/// The normalized project model of one instance. Paths are workspace-relative.
package struct BuildModel: Equatable, Sendable, Decodable {
    package struct Project: Equatable, Identifiable, Sendable, Decodable {
        package let id: String
        package let path: String
        package let name: String
        package let displayName: String?
        package let parentID: String?
        package let properties: [String: String]

        package init(
            id: String, path: String, name: String, displayName: String? = nil,
            parentID: String? = nil, properties: [String: String] = [:]
        ) {
            self.id = id; self.path = path; self.name = name; self.displayName = displayName
            self.parentID = parentID; self.properties = properties
        }

        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            path = try values.decode(String.self, forKey: .path)
            name = try values.decode(String.self, forKey: .name)
            displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            parentID = try values.decodeIfPresent(String.self, forKey: .parentID)
            properties = try values.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        }

        private enum CodingKeys: String, CodingKey { case id, path, name, displayName, parentID, properties }
    }

    package struct Target: Equatable, Identifiable, Sendable, Decodable {
        package let id: String
        package let projectID: String
        package let name: String
        package let path: String
        package let tags: [String]
        package let properties: [String: String]

        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            projectID = try values.decode(String.self, forKey: .projectID)
            name = try values.decode(String.self, forKey: .name)
            path = try values.decode(String.self, forKey: .path)
            tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
            properties = try values.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        }

        private enum CodingKeys: String, CodingKey { case id, projectID, name, path, tags, properties }
    }

    package struct Task: Equatable, Identifiable, Sendable, Decodable {
        package let id: String
        package let projectID: String
        package let name: String
        package let path: String
        package let displayName: String?
        package let description: String?
        /// The `fromModel` task declaration whose arguments run it.
        package let template: String
        package let group: BuildTaskGroup
        package let execution: BuildExecution
        package let properties: [String: String]

        package init(
            id: String, projectID: String, name: String, path: String, template: String,
            group: BuildTaskGroup = .other, execution: BuildExecution = .task,
            properties: [String: String] = [:]
        ) {
            self.id = id; self.projectID = projectID; self.name = name; self.path = path
            displayName = nil; description = nil
            self.template = template; self.group = group; self.execution = execution
            self.properties = properties
        }

        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            projectID = try values.decode(String.self, forKey: .projectID)
            name = try values.decode(String.self, forKey: .name)
            path = try values.decode(String.self, forKey: .path)
            displayName = try values.decodeIfPresent(String.self, forKey: .displayName)
            description = try values.decodeIfPresent(String.self, forKey: .description)
            template = try values.decode(String.self, forKey: .template)
            group = try values.decodeIfPresent(BuildTaskGroup.self, forKey: .group) ?? .other
            execution = try values.decodeIfPresent(BuildExecution.self, forKey: .execution) ?? .task
            properties = try values.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case id, projectID, name, path, displayName, description, template, group, execution, properties
        }
    }

    package struct ContentRoot: Equatable, Sendable, Decodable {
        package let projectID: String
        package let path: String
        /// `source`, `testSource`, `generatedSource`, `excluded`, ….
        package let kind: String
    }

    package let projects: [Project]
    package let targets: [Target]
    package let tasks: [Task]
    package let contentRoots: [ContentRoot]
    /// Values the model offers for `choicesFromModel` options.
    package let optionValues: [String: [String]]
    /// True when a Core bound dropped entries.
    package let truncated: Bool

    package init(
        projects: [Project], targets: [Target] = [], tasks: [Task] = [],
        contentRoots: [ContentRoot] = [], optionValues: [String: [String]] = [:], truncated: Bool = false
    ) {
        self.projects = projects; self.targets = targets; self.tasks = tasks
        self.contentRoots = contentRoots; self.optionValues = optionValues; self.truncated = truncated
    }

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([Project].self, forKey: .projects) ?? []
        targets = try values.decodeIfPresent([Target].self, forKey: .targets) ?? []
        tasks = try values.decodeIfPresent([Task].self, forKey: .tasks) ?? []
        contentRoots = try values.decodeIfPresent([ContentRoot].self, forKey: .contentRoots) ?? []
        optionValues = try values.decodeIfPresent([String: [String]].self, forKey: .optionValues) ?? [:]
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case projects, targets, tasks, contentRoots, optionValues, truncated
    }
}

// MARK: Invocation

/// The executables of one build system on this platform, in Core's order.
package struct BuildInvocation: Equatable, Sendable {
    package enum Executable: Equatable, Sendable {
        /// A wrapper script inside the project. Always runs project code.
        case projectFile(path: String, requires: [String])
        /// A path below the directory one environment variable names.
        case environment(variable: String, path: String)
        /// A bare command name the host's tool discovery resolves.
        case command(String)
        /// The executable of a declared runtime dependency.
        case runtime(String)
    }

    package struct RuntimeDependency: Equatable, Sendable {
        package let id: String
        package let displayName: String?
        /// `java`, `node`, and `go` follow the user's runtime settings.
        package let hostManaged: Bool
        package let minimumVersion: String?
        package let executables: [Executable]
        package let versionArguments: [String]?

        package init(
            id: String, displayName: String? = nil, hostManaged: Bool, minimumVersion: String? = nil,
            executables: [Executable] = [], versionArguments: [String]? = nil
        ) {
            self.id = id; self.displayName = displayName; self.hostManaged = hostManaged
            self.minimumVersion = minimumVersion; self.executables = executables
            self.versionArguments = versionArguments
        }
    }

    package let executables: [Executable]
    /// The only environment variables `environment` candidates may read.
    package let environmentInputs: [String]
    package let runtimeDependencies: [RuntimeDependency]
    package let versionArguments: [String]?
    package let minimumVersion: String?

    package init(
        executables: [Executable], environmentInputs: [String] = [],
        runtimeDependencies: [RuntimeDependency] = [], versionArguments: [String]? = nil,
        minimumVersion: String? = nil
    ) {
        self.executables = executables; self.environmentInputs = environmentInputs
        self.runtimeDependencies = runtimeDependencies; self.versionArguments = versionArguments
        self.minimumVersion = minimumVersion
    }
}

package struct BuildVersionCheck: Equatable, Sendable, Decodable {
    package let satisfied: Bool
    package let version: String?

    package init(satisfied: Bool, version: String?) {
        self.satisfied = satisfied; self.version = version
    }
}

/// The executable and environment one run uses.
package struct ResolvedBuildTool: Equatable, Sendable {
    package let executableURL: URL
    package let environment: [String: String]
    /// True for a wrapper inside the project, whatever the plugin declares.
    package let executesProjectCode: Bool
    package let version: String?

    package init(executableURL: URL, environment: [String: String], executesProjectCode: Bool, version: String?) {
        self.executableURL = executableURL; self.environment = environment
        self.executesProjectCode = executesProjectCode; self.version = version
    }
}

/// No candidate of a build system, or one of its runtimes, was usable.
package struct BuildToolResolutionError: LocalizedError, Equatable, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}

/// Picks the executable of one run from Core's candidate list. The probe
/// output is handed back through `checkVersion`, which Rust Core answers.
@MainActor
package protocol BuildToolResolving: AnyObject {
    func resolve(
        _ invocation: BuildInvocation,
        displayName: String,
        workspaceURL: URL,
        checkVersion: @escaping @Sendable (_ runtime: String?, _ output: String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool
}

// MARK: Options

package struct BuildResolvedOption: Equatable, Identifiable, Sendable, Decodable {
    package enum Kind: String, Equatable, Sendable {
        case boolean, singleSelect, multiSelect, text, file, directory
    }
    package struct Choice: Equatable, Sendable, Decodable {
        package let value: String
        package let title: String?
        package let fromModel: Bool

        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            value = try values.decode(String.self, forKey: .value)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            fromModel = try values.decodeIfPresent(Bool.self, forKey: .fromModel) ?? false
        }

        private enum CodingKeys: String, CodingKey { case value, title, fromModel }
    }

    package let id: String
    package let displayName: String
    /// Nil for a kind this host does not know; such an option is not shown.
    package let kind: Kind?
    package let value: ToolingJSONValue
    /// `user` when the value came from the stored options.
    package let source: String
    package let choices: [Choice]
    package let allowCustom: Bool

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        kind = Kind(rawValue: try values.decode(String.self, forKey: .kind))
        value = try values.decodeIfPresent(ToolingJSONValue.self, forKey: .value) ?? .null
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "unset"
        choices = try values.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        allowCustom = try values.decodeIfPresent(Bool.self, forKey: .allowCustom) ?? false
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, kind, value, source, choices, allowCustom }
}

package struct BuildOptionsResolution: Equatable, Sendable, Decodable {
    package let options: [BuildResolvedOption]
    /// Options whose stored value lost entries; the host stores the effective value.
    package let dropped: [String]
    package let fingerprint: String
}

/// Stored option values, keyed by workspace and build-system ID, which is
/// how `build.detect` takes them.
@MainActor
package protocol BuildOptionsStoring: AnyObject {
    func options(workspaceURL: URL, buildSystemID: String) -> [String: ToolingJSONValue]
    func setOptions(_ options: [String: ToolingJSONValue], workspaceURL: URL, buildSystemID: String)
}

// MARK: Plans

/// Inputs every plan request shares.
package struct BuildPlanContext: Equatable, Sendable {
    /// Workspace-relative instance root.
    package let root: String
    package let options: [String: ToolingJSONValue]
    package let pluginDirectory: URL?
    package let workspaceStateDirectory: URL?

    package init(
        root: String, options: [String: ToolingJSONValue],
        pluginDirectory: URL? = nil, workspaceStateDirectory: URL? = nil
    ) {
        self.root = root; self.options = options
        self.pluginDirectory = pluginDirectory; self.workspaceStateDirectory = workspaceStateDirectory
    }
}

/// A project, target, or model task a plan addresses.
package struct BuildSelection: Equatable, Sendable, Encodable {
    package let name: String
    /// Workspace-relative directory.
    package let path: String?
    package let tags: [String]
    package let execution: BuildExecution?
    package let properties: [String: String]

    package init(
        name: String, path: String?, tags: [String] = [], execution: BuildExecution? = nil,
        properties: [String: String] = [:]
    ) {
        self.name = name; self.path = path; self.tags = tags; self.execution = execution
        self.properties = properties
    }

    package init(project: BuildModel.Project) {
        self.init(name: project.name, path: project.path, properties: project.properties)
    }

    package init(task: BuildModel.Task) {
        self.init(name: task.name, path: task.path, execution: task.execution, properties: task.properties)
    }

    package init(target: BuildModel.Target) {
        self.init(name: target.name, path: target.path, tags: target.tags, properties: target.properties)
    }
}

package struct BuildTaskRequest: Equatable, Sendable {
    /// A task declaration ID; the model task's `template` for model tasks.
    package let task: String
    package let project: BuildSelection?
    package let target: BuildSelection?
    package let modelTask: BuildSelection?
    package let userArguments: [String]

    package init(
        task: String, project: BuildSelection? = nil, target: BuildSelection? = nil,
        modelTask: BuildSelection? = nil, userArguments: [String] = []
    ) {
        self.task = task; self.project = project; self.target = target
        self.modelTask = modelTask; self.userArguments = userArguments
    }
}

package struct BuildTestRequest: Equatable, Sendable {
    package let project: BuildSelection?
    package let target: BuildSelection?
    package let suite: String?
    package let testCase: String?
    package let userArguments: [String]
    /// Workspace-relative project directories of the current model, so a
    /// workspace run collects every project's reports.
    package let projects: [String]

    package init(
        project: BuildSelection? = nil, target: BuildSelection? = nil, suite: String? = nil,
        testCase: String? = nil, userArguments: [String] = [], projects: [String] = []
    ) {
        self.project = project; self.target = target; self.suite = suite; self.testCase = testCase
        self.userArguments = userArguments; self.projects = projects
    }
}

/// An argv the host runs as Core expanded it.
package struct BuildProcessPlan: Equatable, Sendable {
    package enum Output: String, Equatable, Sendable {
        case stdout, outputFile
    }

    package let arguments: [String]
    /// Option contributions, layered over the tool's environment.
    package let environment: [String: String]
    /// Workspace-relative.
    package let workingDirectory: String
    package let execution: BuildExecution
    package let optionFingerprint: String
    /// Set for model and dependency commands.
    package let output: Output?
    package let executesProjectCode: Bool
    package let mayUseNetwork: Bool

    package init(
        arguments: [String], environment: [String: String] = [:], workingDirectory: String,
        execution: BuildExecution = .task, optionFingerprint: String, output: Output? = nil,
        executesProjectCode: Bool = false, mayUseNetwork: Bool = false
    ) {
        self.arguments = arguments; self.environment = environment
        self.workingDirectory = workingDirectory; self.execution = execution
        self.optionFingerprint = optionFingerprint; self.output = output
        self.executesProjectCode = executesProjectCode; self.mayUseNetwork = mayUseNetwork
    }
}

/// A model or dependency plan: a command, or a request for the plugin's
/// Provider process.
package enum BuildOutputPlan: Equatable, Sendable {
    case process(BuildProcessPlan)
    case provider(method: String)
}

package struct BuildTestPlan: Equatable, Sendable {
    /// How Core reads the run's results; nil when it cannot.
    package enum Results: Equatable, Sendable {
        case reports(decoder: String, patterns: [String])
        case hostIntegration
    }

    package let process: BuildProcessPlan
    package let results: Results?

    package init(process: BuildProcessPlan, results: Results?) {
        self.process = process; self.results = results
    }
}

// MARK: Outputs

/// What a finished model or dependency command left for Core to decode.
package enum BuildCommandOutput: Equatable, Sendable {
    case stdout(String)
    case outputFile(URL)
}

package struct BuildTestResults: Equatable, Sendable, Decodable {
    package struct TestCase: Equatable, Identifiable, Sendable, Decodable {
        package enum Status: String, Equatable, Sendable {
            case passed, failed, error, skipped
        }

        package let suite: String
        package let name: String
        package let status: Status
        package let message: String?
        package let durationMillis: Int?
        /// Workspace-relative source file.
        package let path: String?
        package let line: Int?
        package let invocations: Int
        package var id: String { suite + "#" + name }

        package init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            suite = try values.decode(String.self, forKey: .suite)
            name = try values.decode(String.self, forKey: .case)
            status = Status(rawValue: try values.decode(String.self, forKey: .status)) ?? .error
            message = try values.decodeIfPresent(String.self, forKey: .message)
            durationMillis = try values.decodeIfPresent(Int.self, forKey: .durationMillis)
            path = try values.decodeIfPresent(String.self, forKey: .path)
            line = try values.decodeIfPresent(Int.self, forKey: .line)
            invocations = try values.decodeIfPresent(Int.self, forKey: .invocations) ?? 1
        }

        private enum CodingKeys: String, CodingKey {
            case suite, `case`, status, message, durationMillis, path, line, invocations
        }
    }

    package struct Summary: Equatable, Sendable, Decodable {
        package let total: Int
        package let passed: Int
        package let failed: Int
        package let errors: Int
        package let skipped: Int
    }

    package let tests: [TestCase]
    package let summary: Summary
    package let success: Bool
}

package struct BuildTestResultsRequest: Equatable, Sendable {
    package let workspaceURL: URL
    package let root: String
    /// Workspace-relative directory of the project that ran.
    package let project: String?
    package let projects: [String]
    package let output: String
    package let notBefore: Date?
    package let suite: String?

    package init(
        workspaceURL: URL, root: String, project: String?, projects: [String], output: String,
        notBefore: Date?, suite: String?
    ) {
        self.workspaceURL = workspaceURL; self.root = root; self.project = project
        self.projects = projects; self.output = output; self.notBefore = notBefore; self.suite = suite
    }
}

package struct BuildDiagnostic: Equatable, Sendable, Decodable {
    /// Workspace-relative.
    package let path: String
    package let line: Int
    package let column: Int?
    /// `error`, `warning`, or `info`.
    package let severity: String
    package let message: String
}

package struct BuildDependencyNode: Equatable, Sendable, Decodable {
    package let name: String
    package let group: String?
    package let version: String?
    package let scope: String?
    package let properties: [String: String]
    package let children: [BuildDependencyNode]

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        group = try values.decodeIfPresent(String.self, forKey: .group)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        scope = try values.decodeIfPresent(String.self, forKey: .scope)
        properties = try values.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
        children = try values.decodeIfPresent([BuildDependencyNode].self, forKey: .children) ?? []
    }

    private enum CodingKeys: String, CodingKey { case name, group, version, scope, properties, children }
}

package struct BuildDependencyTree: Equatable, Sendable, Decodable {
    package let dependencies: [BuildDependencyNode]
    package let truncated: Bool
}

/// A digest of the files the model depends on, and the exact
/// workspace-relative paths to watch for it, present or not.
package struct BuildSyncState: Equatable, Sendable, Decodable {
    package let fingerprint: String
    package let watch: [String]

    package init(fingerprint: String, watch: [String]) {
        self.fingerprint = fingerprint; self.watch = watch
    }
}

// MARK: Core operations

/// The `build.*` commands of Rust Core. Implementations throw
/// `DeclarativePluginRejection`. Detection, decoding, and fingerprints read
/// workspace files, so callers keep them off the main actor.
package protocol BuildSystemPlanning: Sendable {
    func detect(
        workspaceURL: URL,
        sources: [BuildSystemPluginSource],
        options: [String: [String: ToolingJSONValue]]
    ) throws -> BuildDetection
    func invocationPlan(_ target: BuildSystemTarget, root: String) throws -> BuildInvocation
    func checkToolVersion(_ target: BuildSystemTarget, runtime: String?, output: String) throws -> BuildVersionCheck
    func resolveOptions(
        _ target: BuildSystemTarget,
        options: [String: ToolingJSONValue],
        modelValues: [String: [String]]?
    ) throws -> BuildOptionsResolution
    func modelPlan(_ target: BuildSystemTarget, context: BuildPlanContext, outputFile: URL?) throws -> BuildOutputPlan
    func taskPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTaskRequest) throws
        -> BuildProcessPlan
    func testPlan(_ target: BuildSystemTarget, context: BuildPlanContext, request: BuildTestRequest) throws
        -> BuildTestPlan
    func dependencyPlan(
        _ target: BuildSystemTarget,
        context: BuildPlanContext,
        project: BuildSelection?,
        outputFile: URL?
    ) throws -> BuildOutputPlan
    func decodeModel(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        output: BuildCommandOutput,
        options: [String: ToolingJSONValue]
    ) throws -> BuildModel
    func decodeTestResults(_ target: BuildSystemTarget, request: BuildTestResultsRequest) throws -> BuildTestResults
    func decodeDiagnostics(_ target: BuildSystemTarget, workspaceURL: URL, root: String, output: String) throws
        -> [BuildDiagnostic]
    func decodeDependencies(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        project: String?,
        output: BuildCommandOutput
    ) throws -> BuildDependencyTree
    func syncFingerprint(
        _ target: BuildSystemTarget,
        workspaceURL: URL,
        root: String,
        projects: [String],
        options: [String: ToolingJSONValue]
    ) throws -> BuildSyncState
}

// MARK: Host storage

/// Writable files of one build-system run. Everything lives under the
/// plugin's state directory, never in the app bundle or the plugin package.
package protocol BuildSystemStateLocating: Sendable {
    /// `${workspaceStateDir}` of one build system in one workspace, created
    /// when missing.
    func workspaceStateDirectory(pluginID: String, buildSystemID: String, workspaceURL: URL) throws -> URL
    /// A fresh, not yet existing path for one `${outputFile}`.
    func allocateOutputFile(in workspaceStateDirectory: URL) throws -> URL
    func removeOutputFile(_ url: URL)
}

// MARK: Processes

package struct BuildCommandRequest: Equatable, Sendable {
    package let executableURL: URL
    package let arguments: [String]
    package let workingDirectory: URL
    package let environment: [String: String]
    /// Keeps stdout apart from the streamed output and returns it, so stderr
    /// noise cannot corrupt a document Core decodes.
    package let capturesStandardOutput: Bool
    package let timeout: Duration?

    package init(
        executableURL: URL, arguments: [String], workingDirectory: URL, environment: [String: String],
        capturesStandardOutput: Bool = false, timeout: Duration? = nil
    ) {
        self.executableURL = executableURL; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.environment = environment
        self.capturesStandardOutput = capturesStandardOutput; self.timeout = timeout
    }
}

package struct BuildCommandResult: Equatable, Sendable {
    package enum Termination: Equatable, Sendable {
        case exited(Int32)
        case timedOut
    }

    package let termination: Termination
    /// The captured stdout; nil when it was not captured, was not UTF-8, or
    /// passed the output bound.
    package let standardOutput: String?

    package init(termination: Termination, standardOutput: String? = nil) {
        self.termination = termination; self.standardOutput = standardOutput
    }
}

/// Runs one build command in its own process group.
package protocol BuildCommandRunning: Sendable {
    /// Streams stderr, and stdout unless it is captured, to `onOutput` in
    /// order. Cancelling the calling task ends the process group, and the
    /// call then throws `CancellationError`.
    func run(
        _ request: BuildCommandRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> BuildCommandResult
}
