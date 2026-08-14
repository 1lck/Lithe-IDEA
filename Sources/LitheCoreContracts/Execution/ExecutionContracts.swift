import Foundation

package struct RunOptions: Codable, Hashable, Sendable {
    package struct JavaCapability: Codable, Hashable, Sendable {
        package var homePath = ""
        package var mavenExecutablePath = ""
        package var mavenJavaHomePath = ""
        package var vmArguments = ""
        package var activeMavenProfiles: Set<String> = []

        private enum CodingKeys: String, CodingKey {
            case homePath, mavenExecutablePath, mavenJavaHomePath, vmArguments, activeMavenProfiles
        }

        package init(
            homePath: String = "",
            mavenExecutablePath: String = "",
            mavenJavaHomePath: String = "",
            vmArguments: String = "",
            activeMavenProfiles: Set<String> = []
        ) {
            self.homePath = homePath
            self.mavenExecutablePath = mavenExecutablePath
            self.mavenJavaHomePath = mavenJavaHomePath
            self.vmArguments = vmArguments
            self.activeMavenProfiles = activeMavenProfiles
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            homePath = try container.decodeIfPresent(String.self, forKey: .homePath) ?? ""
            mavenExecutablePath = try container.decodeIfPresent(String.self, forKey: .mavenExecutablePath) ?? ""
            mavenJavaHomePath = try container.decodeIfPresent(String.self, forKey: .mavenJavaHomePath) ?? ""
            vmArguments = try container.decodeIfPresent(String.self, forKey: .vmArguments) ?? ""
            activeMavenProfiles = try container.decodeIfPresent(Set<String>.self, forKey: .activeMavenProfiles) ?? []
        }
    }

    package var workingDirectoryPath = ""
    package var arguments = ""
    package var environment: [String: String] = [:]
    package var java = JavaCapability()

    package init(
        javaHomePath: String = "",
        workingDirectoryPath: String = "",
        vmArguments: String = "",
        programArguments: String = "",
        activeProfiles: Set<String> = [],
        mavenExecutablePath: String = "",
        mavenJavaHomePath: String = "",
        environment: [String: String] = [:]
    ) {
        self.workingDirectoryPath = workingDirectoryPath
        arguments = programArguments
        self.environment = environment
        java = JavaCapability(
            homePath: javaHomePath,
            mavenExecutablePath: mavenExecutablePath,
            mavenJavaHomePath: mavenJavaHomePath,
            vmArguments: vmArguments,
            activeMavenProfiles: activeProfiles
        )
    }

    package var javaHomePath: String {
        get { java.homePath }
        set { java.homePath = newValue }
    }
    package var vmArguments: String {
        get { java.vmArguments }
        set { java.vmArguments = newValue }
    }
    package var mavenExecutablePath: String {
        get { java.mavenExecutablePath }
        set { java.mavenExecutablePath = newValue }
    }
    package var mavenJavaHomePath: String {
        get { java.mavenJavaHomePath }
        set { java.mavenJavaHomePath = newValue }
    }
    package var programArguments: String {
        get { arguments }
        set { arguments = newValue }
    }
    package var activeProfiles: Set<String> {
        get { java.activeMavenProfiles }
        set { java.activeMavenProfiles = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case workingDirectoryPath, arguments, environment, java
        case javaHomePath, vmArguments, programArguments, activeProfiles
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath) ?? ""
        arguments = try container.decodeIfPresent(String.self, forKey: .arguments)
            ?? container.decodeIfPresent(String.self, forKey: .programArguments)
            ?? ""
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        java = try container.decodeIfPresent(JavaCapability.self, forKey: .java) ?? JavaCapability(
            homePath: try container.decodeIfPresent(String.self, forKey: .javaHomePath) ?? "",
            vmArguments: try container.decodeIfPresent(String.self, forKey: .vmArguments) ?? "",
            activeMavenProfiles: try container.decodeIfPresent(Set<String>.self, forKey: .activeProfiles) ?? []
        )
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workingDirectoryPath, forKey: .workingDirectoryPath)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(environment, forKey: .environment)
        try container.encode(java, forKey: .java)
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
    func resolve(_ plan: SharedLaunchPlan, projectURL: URL, options: RunOptions) throws -> ResolvedRunExecutable
    func refreshCandidates(projectURL: URL) async
    func candidates(projectURL: URL) -> [ProjectToolchainCandidate]
}

package extension RunExecutableResolving {
    func refreshCandidates(projectURL _: URL) async {}
    func candidates(projectURL _: URL) -> [ProjectToolchainCandidate] { [] }
}

@MainActor
package protocol RunRuntimePort: AnyObject {
    func setActiveServiceJavaHomePath(_ path: String)
    func javaHomeURL(overridePath: String?) -> URL?
    func mavenJavaHomeURL(overridePath: String?) -> URL?
    func runConfigurationToolchainCandidates(
        for project: MavenProject?,
        projectRoot: URL?,
        javaHomeOverride: String?,
        mavenExecutableOverride: String?
    ) -> [ProjectToolchainCandidate]
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

package protocol RunServerPortParsing: Sendable {
    func serverPort(content: String, fileExtension: String) -> Int?
}

package enum LanguageTestItemKind: String, Equatable, Sendable {
    case workspace, file, testCase
}

package struct LanguageTestItem: Identifiable, Equatable, Sendable {
    package let id: String
    package let providerID: String
    package let label: String
    package let kind: LanguageTestItemKind
    package let fileURL: URL?

    package init(id: String, providerID: String, label: String, kind: LanguageTestItemKind, fileURL: URL?) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.kind = kind
        self.fileURL = fileURL
    }
}

package enum LanguageTestScope: Equatable, Sendable {
    case workspace
    case file(URL)
    case testCase(identifier: String, fileURL: URL?)
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
