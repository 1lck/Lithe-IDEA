import Foundation

enum ProjectRunConfigurationStatus: Equatable, Sendable {
    case missing
    case ready
    case invalid(String)
}

enum RunConfigurationRecoveryAction: Equatable, Sendable {
    case none
    case regenerate
    case editConfiguration
    case fixPermissions
    case upgradeApplication
}

struct RunConfigurationDiagnostic: Equatable, Identifiable, Sendable {
    let configurationID: String?
    let code: String
    let message: String

    var id: String { [configurationID, code, message].compactMap { $0 }.joined(separator: ":") }
}

struct ProjectRunConfigurationInspection: Equatable, Sendable {
    let status: ProjectRunConfigurationStatus
    let diagnostics: [RunConfigurationDiagnostic]
    var recoveryAction: RunConfigurationRecoveryAction = .none
    var recoveryPath: String? = nil
}

enum RunConfigurationGenerationState: Equatable, Sendable {
    case idle
    case succeeded(entryCount: Int)
    case noEntries
    case failed(String)
}

enum RunConfigurationSaveScope: String, CaseIterable, Identifiable, Sendable {
    case local
    case project

    var id: String { rawValue }
}

enum RunConfigurationSource: String, Sendable {
    case generated
    case project
    case local
}

struct EffectiveRunConfiguration: Sendable {
    let configuration: RunConfiguration
    let options: RunOptions
    var source: RunConfigurationSource = .generated
}

struct RunConfigurationResolution: Sendable {
    let configurations: [EffectiveRunConfiguration]
    let diagnostics: [RunConfigurationDiagnostic]
    let defaultConfigurationID: String?
}

struct RunConfigurationOperationFailure: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

struct SharedLaunchPlan: Sendable {
    /// Exactly one of `toolchainID` / `command` is set. A toolchain is resolved
    /// through the IDE's registry; a command is resolved on PATH.
    enum Executable: Sendable {
        case toolchain(String)
        case command(String)
    }

    let executable: Executable
    let arguments: [String]
    let workingDirectory: String
    var environment: [String: String] = [:]

    var toolchainID: String? {
        if case .toolchain(let value) = executable { return value }
        return nil
    }
}

struct RunConfigurationGenerationResult: Sendable {
    let entryCount: Int
}

struct RunConfigurationDraft: Sendable {
    let name: String
    let kind: RunConfigurationKind
    let modulePath: String
    let mainClass: String
    let scope: RunConfigurationSaveScope
}

struct RunConfigurationDocumentMutation: Sendable {
    let configurationID: String?
    let document: Data
}

protocol RunConfigurationDocumentMutating: Sendable {
    func updateOptionsDocument(
        at projectURL: URL,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        options: RunOptions
    ) throws -> RunConfigurationDocumentMutation
    func createConfigurationDocument(
        at projectURL: URL,
        draft: RunConfigurationDraft
    ) throws -> RunConfigurationDocumentMutation
}

struct ProjectToolchainSelection: Equatable, Sendable {
    var javaHomePath = ""
    var mavenExecutablePath = ""
    var mavenJavaHomePath = ""
}

struct ProjectToolchainCandidate: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let version: String
    let vendor: String
}

protocol ProjectToolchainConfigurationSource: Sendable {
    func loadLocalToolchains(at projectURL: URL) -> ProjectToolchainSelection
    func saveLocalToolchains(_ selection: ProjectToolchainSelection, at projectURL: URL) throws
}

protocol RunConfigurationOperations: ProjectToolchainConfigurationSource, Sendable {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String]
    ) throws -> RunConfigurationGenerationResult
    func resolve(
        at projectURL: URL,
        toolchainCandidates: [ProjectToolchainCandidate]
    ) throws -> RunConfigurationResolution
    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan
    func saveOptions(
        _ options: RunOptions,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws
}
