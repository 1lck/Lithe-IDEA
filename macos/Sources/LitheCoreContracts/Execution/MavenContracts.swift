import Foundation

package enum MavenSourceRootKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case mainJava
    case mainResources
    case testJava
    case testResources
    case generatedMain
    case generatedTest

    package var id: String { rawValue }
    package var title: String {
        switch self {
        case .mainJava: "main Java"
        case .mainResources: "main resources"
        case .testJava: "test Java"
        case .testResources: "test resources"
        case .generatedMain: "generated main"
        case .generatedTest: "generated test"
        }
    }
}

package struct MavenSourceRoot: Identifiable, Hashable, Sendable {
    package let path: String
    package let kind: MavenSourceRootKind

    package init(path: String, kind: MavenSourceRootKind) {
        self.path = path
        self.kind = kind
    }

    package var id: String { "\(kind.rawValue):\(path)" }
}

package struct MavenProject: Identifiable, Hashable, Sendable {
    package let rootURL: URL
    package let pomURL: URL
    package let groupID: String?
    package let artifactID: String
    package let version: String?
    package let packaging: String
    package let sourceRoots: [MavenSourceRoot]
    package let modules: [MavenModule]
    package let profiles: [MavenProfile]
    package let hasWrapper: Bool

    package init(
        rootURL: URL,
        pomURL: URL,
        groupID: String?,
        artifactID: String,
        version: String?,
        packaging: String,
        modules: [MavenModule],
        profiles: [MavenProfile],
        hasWrapper: Bool,
        sourceRoots: [MavenSourceRoot] = []
    ) {
        self.rootURL = rootURL
        self.pomURL = pomURL
        self.groupID = groupID
        self.artifactID = artifactID
        self.version = version
        self.packaging = packaging
        self.sourceRoots = sourceRoots
        self.modules = modules
        self.profiles = profiles
        self.hasWrapper = hasWrapper
    }

    package var id: String { rootURL.path }
    package var displayName: String { artifactID.isEmpty ? rootURL.lastPathComponent : artifactID }
    package var isMultiModule: Bool { !modules.isEmpty }
    package var allModules: [MavenModule] { modules + modules.flatMap { $0.allModules } }
}

package struct MavenModule: Identifiable, Hashable, Sendable {
    package let relativePath: String
    package let url: URL
    package let groupID: String?
    package let artifactID: String
    package let version: String?
    package let packaging: String
    package let sourceRoots: [MavenSourceRoot]
    package let modules: [MavenModule]

    package init(
        relativePath: String,
        url: URL,
        groupID: String?,
        artifactID: String,
        version: String?,
        packaging: String,
        modules: [MavenModule],
        sourceRoots: [MavenSourceRoot] = []
    ) {
        self.relativePath = relativePath
        self.url = url
        self.groupID = groupID
        self.artifactID = artifactID
        self.version = version
        self.packaging = packaging
        self.sourceRoots = sourceRoots
        self.modules = modules
    }

    package var id: String { relativePath }
    package var displayName: String { artifactID.isEmpty ? relativePath : artifactID }
    package var allModules: [MavenModule] { modules + modules.flatMap { $0.allModules } }
}

package struct MavenProfile: Identifiable, Hashable, Sendable {
    package let id: String
    package let isActiveByDefault: Bool

    package init(id: String, isActiveByDefault: Bool) {
        self.id = id
        self.isActiveByDefault = isActiveByDefault
    }
}

package enum MavenLifecyclePhase: String, CaseIterable, Identifiable, Sendable {
    case clean, validate, compile, test
    case packagePhase = "package"
    case verify, install, site, deploy

    package var id: String { rawValue }
    package var title: String { rawValue }
    package var systemImage: String {
        switch self {
        case .clean: "trash"
        case .validate: "checkmark.seal"
        case .compile: "hammer"
        case .test: "checkmark.circle"
        case .packagePhase: "shippingbox"
        case .verify: "checkmark.shield"
        case .install: "arrow.down.to.line"
        case .site: "globe"
        case .deploy: "arrow.up.to.line"
        }
    }
}

package enum MavenIssueSeverity: String, Sendable {
    case error, warning, info

    package var systemImage: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

package struct MavenBuildIssue: Identifiable, Hashable, Sendable {
    package let id: String
    package let fileURL: URL?
    package let line: Int?
    package let column: Int?
    package let severity: MavenIssueSeverity
    package let message: String

    package init(id: String, fileURL: URL?, line: Int?, column: Int?, severity: MavenIssueSeverity, message: String) {
        self.id = id
        self.fileURL = fileURL
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }

    package var locationTitle: String {
        guard let fileURL else { return "Build output" }
        let location = [line, column].compactMap { $0.map(String.init) }.joined(separator: ":")
        return location.isEmpty ? fileURL.lastPathComponent : fileURL.lastPathComponent + ":" + location
    }
}

package struct MavenTestFailureDetail: Identifiable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let kind: String
    package let message: String?
    package let fileURL: URL?
    package let line: Int?
    package let column: Int?

    package init(
        id: String,
        name: String,
        kind: String,
        message: String?,
        fileURL: URL?,
        line: Int?,
        column: Int?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.message = message
        self.fileURL = fileURL
        self.line = line
        self.column = column
    }
}

package struct MavenTestResults: Equatable, Sendable {
    package let testsRun: Int
    package let failures: Int
    package let errors: Int
    package let skipped: Int
    package let passed: Int
    package let success: Bool
    package let failureDetails: [MavenTestFailureDetail]
    /// Per-method outcomes read from the run's XML reports; empty when the
    /// run was not identified or wrote no readable reports.
    package let testCases: [MavenTestCaseOutcome]

    package init(
        testsRun: Int,
        failures: Int,
        errors: Int,
        skipped: Int,
        passed: Int,
        success: Bool,
        failureDetails: [MavenTestFailureDetail],
        testCases: [MavenTestCaseOutcome] = []
    ) {
        self.testsRun = testsRun
        self.failures = failures
        self.errors = errors
        self.skipped = skipped
        self.passed = passed
        self.success = success
        self.failureDetails = failureDetails
        self.testCases = testCases
    }
}

/// One test method's outcome from Core's `maven.testResults` reports.
///
/// Note: 设计见 .agents/notes/implemented/architecture/2026-09-22-editor-run-markers-and-test-outcomes.md
package struct MavenTestCaseOutcome: Codable, Equatable, Sendable {
    /// Binary class name, such as `demo.OrderTest$Refunds`.
    package let className: String
    package let method: String
    /// `passed`, `failed`, `error`, or `skipped`.
    package let status: String
    package let message: String?
    package let invocations: Int

    package init(className: String, method: String, status: String, message: String? = nil, invocations: Int = 1) {
        self.className = className
        self.method = method
        self.status = status
        self.message = message
        self.invocations = invocations
    }
}

/// Identifies the XML reports a finished Maven test run wrote.
package struct MavenTestReportRequest: Codable, Equatable, Sendable {
    /// Workspace-relative module directory, when the run selected one.
    package let module: String?
    /// Workspace-relative test file; Core finds its module when `module` is nil.
    package let sourcePath: String?
    /// Binary class names; empty reads every report the run wrote.
    package let classes: [String]
    /// Run start in Unix milliseconds; older reports belong to earlier runs.
    package let notBeforeMillis: UInt64

    package init(module: String? = nil, sourcePath: String? = nil, classes: [String], notBeforeMillis: UInt64) {
        self.module = module
        self.sourcePath = sourcePath
        self.classes = classes
        self.notBeforeMillis = notBeforeMillis
    }
}

package enum MavenProjectLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

package enum MavenTaskState: Equatable, Sendable {
    case idle
    case running
    case stopping
    case cancelled
    case failed(String)
}

package struct MavenPortableConfiguration: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var selectedProfiles: [String]
    package var customProfiles: [String]
    package var skipTests: Bool

    package init(
        version: Int = currentVersion,
        selectedProfiles: [String] = [],
        customProfiles: [String] = [],
        skipTests: Bool = false
    ) {
        self.version = version
        self.selectedProfiles = selectedProfiles
        self.customProfiles = customProfiles
        self.skipTests = skipTests
    }
}

package struct MavenLocalConfiguration: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package var version: Int
    package var settingsPath: String?
    package var localRepositoryPath: String?
    package var mavenExecutablePath: String?
    package var javaHomePath: String?

    package init(
        version: Int = currentVersion,
        settingsPath: String? = nil,
        localRepositoryPath: String? = nil,
        mavenExecutablePath: String? = nil,
        javaHomePath: String? = nil
    ) {
        self.version = version
        self.settingsPath = settingsPath
        self.localRepositoryPath = localRepositoryPath
        self.mavenExecutablePath = mavenExecutablePath
        self.javaHomePath = javaHomePath
    }
}

package struct MavenStoredConfiguration: Equatable, Sendable {
    package let portable: MavenPortableConfiguration?
    package let local: MavenLocalConfiguration?

    package init(
        portable: MavenPortableConfiguration?,
        local: MavenLocalConfiguration?
    ) {
        self.portable = portable
        self.local = local
    }
}

package struct MavenLaunchContext: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package let version: Int
    package let reactorPath: String
    package let profiles: [String]
    package let settingsPath: String?
    package let localRepositoryPath: String?
    package let skipTests: Bool
    package let mavenExecutablePath: String?
    package let javaHomePath: String?

    package init(
        version: Int = currentVersion,
        reactorPath: String,
        profiles: [String],
        settingsPath: String?,
        localRepositoryPath: String? = nil,
        skipTests: Bool,
        mavenExecutablePath: String?,
        javaHomePath: String?
    ) {
        self.version = version
        self.reactorPath = reactorPath
        self.profiles = profiles
        self.settingsPath = settingsPath
        self.localRepositoryPath = localRepositoryPath
        self.skipTests = skipTests
        self.mavenExecutablePath = mavenExecutablePath
        self.javaHomePath = javaHomePath
    }
}

package struct MavenLaunchPlan: Equatable, Sendable {
    package let version: Int
    package let toolchain: String
    package let arguments: [String]
    package let workingDirectory: String
    package let configurationFingerprint: String

    package init(
        version: Int,
        toolchain: String,
        arguments: [String],
        workingDirectory: String,
        configurationFingerprint: String
    ) {
        self.version = version
        self.toolchain = toolchain
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.configurationFingerprint = configurationFingerprint
    }
}

package enum MavenDependencyResolution: String, Equatable, Sendable {
    case resolved
    case omittedDuplicate
    case omittedConflict
}

package struct MavenDependency: Equatable, Sendable {
    package let modulePath: String
    package let groupID: String
    package let artifactID: String
    package let version: String
    package let type: String
    package let classifier: String?
    package let scope: String
    package let resolution: MavenDependencyResolution
    package let selectedVersion: String?
    /// Version before dependency management replaced it with `version`.
    package let premanagedVersion: String?
    /// Scope before dependency management replaced it with `scope`.
    package let premanagedScope: String?
    /// Declared scope before mediation widened it to `scope`.
    package let originalScope: String?
    /// Wider scope from another path that mediation did not apply here.
    package let ignoredScope: String?
    package let children: [MavenDependency]

    package init(
        modulePath: String,
        groupID: String,
        artifactID: String,
        version: String,
        type: String,
        classifier: String?,
        scope: String,
        resolution: MavenDependencyResolution,
        selectedVersion: String?,
        premanagedVersion: String? = nil,
        premanagedScope: String? = nil,
        originalScope: String? = nil,
        ignoredScope: String? = nil,
        children: [MavenDependency]
    ) {
        self.modulePath = modulePath
        self.groupID = groupID
        self.artifactID = artifactID
        self.version = version
        self.type = type
        self.classifier = classifier
        self.scope = scope
        self.resolution = resolution
        self.selectedVersion = selectedVersion
        self.premanagedVersion = premanagedVersion
        self.premanagedScope = premanagedScope
        self.originalScope = originalScope
        self.ignoredScope = ignoredScope
        self.children = children
    }
}

package struct MavenDependencyTree: Equatable, Sendable {
    package let modulePath: String
    package let dependencies: [MavenDependency]

    package init(modulePath: String, dependencies: [MavenDependency]) {
        self.modulePath = modulePath
        self.dependencies = dependencies
    }
}

package enum MavenDependencyLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready([MavenDependency])
    case failed(String)
    case cancelled
}

package func redactedMavenArgumentsForDisplay(_ arguments: [String]) -> [String] {
    var result: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "-s" || argument == "--settings" {
            result.append(argument)
            if arguments.indices.contains(index + 1) {
                result.append("<settings.xml>")
                index += 2
            } else {
                index += 1
            }
        } else if argument.hasPrefix("--settings=") || argument.hasPrefix("-s=") {
            result.append(String(argument.prefix { $0 != "=" }) + "=<settings.xml>")
            index += 1
        } else if argument.hasPrefix("-Dmaven.repo.local=") {
            result.append("-Dmaven.repo.local=<localRepository>")
            index += 1
        } else {
            result.append(argument)
            index += 1
        }
    }
    return result
}

package struct MavenOperationError: LocalizedError, Equatable, Sendable {
    package let code: String
    package let message: String
    package let details: String?

    package init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    package var errorDescription: String? {
        guard let details, !details.isEmpty else { return message }
        return message + ": " + details
    }
}

package protocol MavenProjectOperations: Sendable {
    func scanMavenProject(at rootURL: URL, files: [URL]) throws -> MavenProject?
    func mavenLaunchPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?,
        goals: [String]
    ) throws -> MavenLaunchPlan
    /// Plans a dependency-tree query that writes the tree to `outputFile`.
    func mavenDependencyPlan(
        at rootURL: URL,
        context: MavenLaunchContext,
        module: String?,
        outputFile: URL
    ) throws -> MavenLaunchPlan
    /// Reads the tree a finished dependency plan wrote to `outputFile`.
    func mavenDependencies(modulePath: String, outputFile: URL) throws -> MavenDependencyTree
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue]
    func mavenTestResults(output: String, projectRoot: URL) -> MavenTestResults?
    func mavenTestResults(
        output: String,
        projectRoot: URL,
        reports: MavenTestReportRequest?
    ) -> MavenTestResults?
}

extension MavenProjectOperations {
    package func mavenDependencyPlan(
        at _: URL,
        context _: MavenLaunchContext,
        module _: String?,
        outputFile _: URL
    ) throws -> MavenLaunchPlan {
        throw MavenOperationError(
            code: "not_supported",
            message: "Maven dependency planning is unavailable."
        )
    }

    package func mavenDependencies(
        modulePath _: String,
        outputFile _: URL
    ) throws -> MavenDependencyTree {
        throw MavenOperationError(
            code: "not_supported",
            message: "Maven dependency parsing is unavailable."
        )
    }

    package func mavenTestResults(output _: String, projectRoot _: URL) -> MavenTestResults? { nil }

    /// Operations without report support fall back to the text summary.
    package func mavenTestResults(
        output: String,
        projectRoot: URL,
        reports _: MavenTestReportRequest?
    ) -> MavenTestResults? {
        mavenTestResults(output: output, projectRoot: projectRoot)
    }
}

/// Platform-owned scratch files that each hold one Maven dependency tree.
///
/// The dependency plugin writes a module's tree to one of these files rather
/// than to the console, so the tree never shares a size budget with Maven's
/// log. Every dependency operation gets its own file and removes it once the
/// operation can no longer produce a result.
package protocol MavenDependencyOutputStoring: Sendable {
    /// Returns a fresh absolute file for one operation, removing any file an
    /// earlier operation left at that location.
    func makeDependencyOutputFile(operationID: String) throws -> URL
    /// Removes an operation's file. A file Maven never wrote is not an error.
    func removeDependencyOutputFile(_ fileURL: URL)
}

package protocol MavenConfigurationStoring: Sendable {
    func loadMavenConfiguration(
        workspaceURL: URL,
        reactorPath: String
    ) throws -> MavenStoredConfiguration
    func saveMavenConfiguration(
        _ configuration: MavenStoredConfiguration,
        workspaceURL: URL,
        reactorPath: String
    ) throws
}

@MainActor
package protocol MavenRuntimePort: AnyObject {
    func mavenExecutable(for project: MavenProject, overridePath: String?) -> URL?
    func mavenProcessEnvironment(javaHomePath: String?) -> [String: String]
}
