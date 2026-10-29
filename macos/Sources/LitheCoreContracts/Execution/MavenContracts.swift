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
    package let project: String?
    package let buildReference: BuildTestReference?
    /// Binary class name, such as `demo.OrderTest$Refunds`.
    package let className: String
    package let method: String
    /// `passed`, `failed`, `error`, or `skipped`.
    package let status: String
    package let message: String?
    package let invocations: Int
    package let durationMillis: Int?

    package init(className: String, method: String, status: String, message: String? = nil, invocations: Int = 1, durationMillis: Int? = nil, project: String? = nil, buildReference: BuildTestReference? = nil) {
        self.project = project
        self.buildReference = buildReference
        self.className = className
        self.method = method
        self.status = status
        self.message = message
        self.invocations = invocations
        self.durationMillis = durationMillis
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

    /// Language-import contexts omit execution-only choices such as Skip Tests.
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        reactorPath = try values.decode(String.self, forKey: .reactorPath)
        profiles = try values.decode([String].self, forKey: .profiles)
        settingsPath = try values.decodeIfPresent(String.self, forKey: .settingsPath)
        localRepositoryPath = try values.decodeIfPresent(String.self, forKey: .localRepositoryPath)
        skipTests = try values.decodeIfPresent(Bool.self, forKey: .skipTests) ?? false
        mavenExecutablePath = try values.decodeIfPresent(String.self, forKey: .mavenExecutablePath)
        javaHomePath = try values.decodeIfPresent(String.self, forKey: .javaHomePath)
    }

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
