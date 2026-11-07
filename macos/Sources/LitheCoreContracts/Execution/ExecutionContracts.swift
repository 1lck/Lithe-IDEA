import Foundation

package struct RunOptions: Codable, Hashable, Sendable {
    package var workingDirectoryPath = ""
    package var arguments = ""
    package var environment: [String: String] = [:]
    package var providerRunOptions: BuildProviderRunOptions?

    /// Reset emits explicit clears for inherited per-Run tools. Omitting this
    /// namespace would keep the previous provider choices on disk.
    package func resettingProviderRunOptions() -> RunOptions {
        let cleared = providerRunOptions?.tools.keys.map { ($0, Optional<FixedToolchainSelection>.none) } ?? []
        return RunOptions(providerRunOptions: BuildProviderRunOptions(tools: Dictionary(uniqueKeysWithValues: cleared)))
    }

    package init(
        workingDirectoryPath: String = "",
        programArguments: String = "",
        environment: [String: String] = [:],
        providerRunOptions: BuildProviderRunOptions? = nil
    ) {
        self.workingDirectoryPath = workingDirectoryPath
        arguments = programArguments
        self.environment = environment
        self.providerRunOptions = providerRunOptions
    }

    package var programArguments: String {
        get { arguments }
        set { arguments = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case workingDirectoryPath, arguments, environment, providerRunOptions
        case programArguments
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath) ?? ""
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
            ?? container.decodeIfPresent(String.self, forKey: .programArguments)
            ?? ""
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        providerRunOptions = try container.decodeIfPresent(BuildProviderRunOptions.self, forKey: .providerRunOptions)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workingDirectoryPath, forKey: .workingDirectoryPath)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encodeIfPresent(providerRunOptions, forKey: .providerRunOptions)
    }
}

package struct SharedLaunchPlan: Sendable {
    package enum Executable: Sendable {
        case toolchain(String)
        case command(String)
    }

    package let executable: Executable
    package let arguments: [String]
    package let workingDirectory: String
    package var environment: [String: String]

    package init(
        executable: Executable,
        arguments: [String],
        workingDirectory: String,
        environment: [String: String] = [:]
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    package var toolchainID: String? {
        if case .toolchain(let value) = executable { return value }
        return nil
    }
}

package struct ProjectToolchainCandidate: Codable, Equatable, Sendable {
    package let id: String
    package let type: String
    package let version: String
    package let vendor: String

    package init(id: String, type: String, version: String, vendor: String) {
        self.id = id
        self.type = type
        self.version = version
        self.vendor = vendor
    }
}

package struct ResolvedRunExecutable: Sendable {
    package let executableURL: URL
    package let environment: [String: String]

    package init(executableURL: URL, environment: [String: String]) {
        self.executableURL = executableURL
        self.environment = environment
    }
}

@MainActor
package protocol RunExecutableResolving: AnyObject {
    /// Acquires fresh plugin-defined tools before the synchronous process handoff.
    func prepare(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) async throws -> ResolvedRunExecutable?
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable
    func refreshCandidates(projectURL: URL) async
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate]
}

package extension RunExecutableResolving {
    func prepare(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) async throws -> ResolvedRunExecutable? { nil }
    func refreshCandidates(projectURL _: URL) async {}
    func candidates(projectURL _: URL) -> [ProjectToolchainCandidate] { [] }
}

package protocol RunFileAccess: Sendable {
    func isDirectory(at url: URL) -> Bool
    func readData(from url: URL) throws -> Data
}

@MainActor
package protocol RunPreferenceStore: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func setData(_ data: Data, forKey key: String)
    func setString(_ value: String, forKey key: String)
}

package enum LanguageTestItemKind: String, Equatable, Sendable {
    case workspace, file, testCase
}

package struct LanguageTestItem: Identifiable, Equatable, Sendable {
    /// A language provider's explicit association with canonical report names.
    /// This is presentation metadata; execution still forwards testIdentifier.
    package struct ReportIdentity: Hashable, Sendable {
        package let suite: String
        package let name: String?
        package init(suite: String, name: String? = nil) { self.suite = suite; self.name = name }
    }
    package let id: String
    package let providerID: String
    package let label: String
    package let kind: LanguageTestItemKind
    package let fileURL: URL?
    /// Stable provider identifier used to run or debug this exact test item.
    package let testIdentifier: String?
    /// Visual nesting below the provider section; source files start at zero.
    package let depth: Int
    package var projectPath: String?
    package var buildReference: BuildTestReference?
    package let reportIdentity: ReportIdentity?

    package init(
        id: String,
        providerID: String,
        label: String,
        kind: LanguageTestItemKind,
        fileURL: URL?,
        testIdentifier: String? = nil,
        depth: Int = 0, projectPath: String? = nil, buildReference: BuildTestReference? = nil,
        reportIdentity: ReportIdentity? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.kind = kind
        self.fileURL = fileURL
        self.testIdentifier = testIdentifier
        self.depth = max(0, depth)
        self.projectPath = projectPath; self.buildReference = buildReference
        self.reportIdentity = reportIdentity
    }
}

/// A report-derived build selector. The current model is revalidated on every
/// rerun; no executable, classpath, source path or cached launch is persisted.
package struct BuildTestReference: Codable, Equatable, Sendable {
    package let pluginID: String
    package let buildSystemID: String
    package let root: String
    package let projectID: String
    package let suite: String
    package let testCase: String?

    package init(pluginID: String, buildSystemID: String, root: String, projectID: String, suite: String, testCase: String?) {
        self.pluginID = pluginID; self.buildSystemID = buildSystemID; self.root = root; self.projectID = projectID
        self.suite = suite; self.testCase = testCase
    }
    package var suiteReference: Self {
        Self(pluginID: pluginID, buildSystemID: buildSystemID, root: root, projectID: projectID, suite: suite, testCase: nil)
    }
}

package enum LanguageTestScope: Equatable, Sendable {
    case workspace
    case file(URL)
    case testCase(identifier: String, fileURL: URL?, buildReference: BuildTestReference? = nil)

    package var buildReference: BuildTestReference? {
        if case .testCase(_, _, let reference) = self { return reference }
        return nil
    }
}

package struct LanguageTestContext: Equatable, Sendable {
    package let workspaceURL: URL
    package let projectFiles: [URL]

    package init(workspaceURL: URL, projectFiles: [URL] = []) {
        self.workspaceURL = workspaceURL.standardizedFileURL
        self.projectFiles = projectFiles.map(\.standardizedFileURL)
    }

    package var projectFileNames: Set<String> {
        Set(projectFiles.map { $0.lastPathComponent.lowercased() })
    }
}

package struct LanguageTestPlan: Sendable {
    package let providerID: String
    package let label: String
    package let frameworkID: String?
    package let launchPlan: SharedLaunchPlan

    package init(providerID: String, label: String, frameworkID: String? = nil, launchPlan: SharedLaunchPlan) {
        self.providerID = providerID
        self.label = label
        self.frameworkID = frameworkID
        self.launchPlan = launchPlan
    }
}

package protocol LanguageTestProvider: Sendable {
    var descriptor: LanguageProviderDescriptor { get }
    func discoverTests(workspaceURL: URL, files: [URL]) -> [LanguageTestItem]
    func discoverTests(context: LanguageTestContext) -> [LanguageTestItem]
    func testPlan(scope: LanguageTestScope, context: LanguageTestContext) throws -> LanguageTestPlan
}

package extension LanguageTestProvider {
    func discoverTests(context: LanguageTestContext) -> [LanguageTestItem] {
        discoverTests(workspaceURL: context.workspaceURL, files: context.projectFiles)
    }
    func testPlan(scope: LanguageTestScope, workspaceURL: URL) throws -> LanguageTestPlan {
        try testPlan(scope: scope, context: LanguageTestContext(workspaceURL: workspaceURL))
    }
}
