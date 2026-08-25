import Foundation

package enum ProjectRunConfigurationStatus: Equatable, Sendable {
    case missing
    case ready
    case invalid(String)
}

package enum RunConfigurationRecoveryAction: Equatable, Sendable {
    case none
    case regenerate
    case editConfiguration
    case fixPermissions
    case upgradeApplication
}

package struct RunConfigurationDiagnostic: Equatable, Identifiable, Sendable {
    package let configurationID: String?
    package let code: String
    package let message: String

    package init(configurationID: String?, code: String, message: String) {
        self.configurationID = configurationID
        self.code = code
        self.message = message
    }

    package var id: String { [configurationID, code, message].compactMap { $0 }.joined(separator: ":") }
}

package struct ProjectRunConfigurationInspection: Equatable, Sendable {
    package let status: ProjectRunConfigurationStatus
    package let diagnostics: [RunConfigurationDiagnostic]
    package var recoveryAction: RunConfigurationRecoveryAction = .none
    package var recoveryPath: String? = nil

    package init(
        status: ProjectRunConfigurationStatus,
        diagnostics: [RunConfigurationDiagnostic],
        recoveryAction: RunConfigurationRecoveryAction = .none,
        recoveryPath: String? = nil
    ) {
        self.status = status
        self.diagnostics = diagnostics
        self.recoveryAction = recoveryAction
        self.recoveryPath = recoveryPath
    }
}

package enum RunConfigurationGenerationState: Equatable, Sendable {
    case idle
    case succeeded(entryCount: Int)
    case noEntries
    case failed(String)
}

package enum RunConfigurationSaveScope: String, CaseIterable, Identifiable, Sendable {
    case local
    case project

    package var id: String { rawValue }
}

package enum RunConfigurationSource: String, Sendable {
    case generated
    case project
    case local
}

package struct EffectiveRunConfiguration: Sendable {
    package let configuration: RunConfiguration
    package let options: RunOptions
    package var source: RunConfigurationSource = .generated

    package init(
        configuration: RunConfiguration,
        options: RunOptions,
        source: RunConfigurationSource = .generated
    ) {
        self.configuration = configuration
        self.options = options
        self.source = source
    }
}

package struct RunConfigurationResolution: Sendable {
    package let configurations: [EffectiveRunConfiguration]
    package let diagnostics: [RunConfigurationDiagnostic]
    package let defaultConfigurationID: String?
    package let projectToolchain: ProjectToolchainSelection

    package init(
        configurations: [EffectiveRunConfiguration],
        diagnostics: [RunConfigurationDiagnostic],
        defaultConfigurationID: String?,
        projectToolchain: ProjectToolchainSelection = ProjectToolchainSelection()
    ) {
        self.configurations = configurations
        self.diagnostics = diagnostics
        self.defaultConfigurationID = defaultConfigurationID
        self.projectToolchain = projectToolchain
    }
}

package struct RunConfigurationOperationFailure: LocalizedError, Sendable {
    package let message: String

    package init(message: String) { self.message = message }

    package var errorDescription: String? { message }
}

package enum RunConfigurationEditorSaveStage: String, Sendable {
    case prepare
    case write
    case reload
}

package struct RunConfigurationEditorSaveFailure: LocalizedError, Sendable {
    package let stage: RunConfigurationEditorSaveStage
    package let message: String

    package init(stage: RunConfigurationEditorSaveStage, message: String) {
        self.stage = stage
        self.message = message
    }

    package var errorDescription: String? {
        switch stage {
        case .prepare:
            "Could not prepare the run configuration: \(message)"
        case .write:
            "Could not write the run configuration: \(message)"
        case .reload:
            "Changes were saved, but Lithe could not reload them: \(message)"
        }
    }
}

package struct RunConfigurationGenerationResult: Sendable {
    package let entryCount: Int
    package init(entryCount: Int) { self.entryCount = entryCount }
}

package struct RunConfigurationDraft: Sendable {
    package let name: String
    package let kind: RunConfigurationKind
    package let modulePath: String
    package let mainClass: String
    package let scope: RunConfigurationSaveScope

    package init(
        name: String,
        kind: RunConfigurationKind,
        modulePath: String,
        mainClass: String,
        scope: RunConfigurationSaveScope
    ) {
        self.name = name
        self.kind = kind
        self.modulePath = modulePath
        self.mainClass = mainClass
        self.scope = scope
    }
}

package struct RunConfigurationDocumentMutation: Sendable {
    package let configurationID: String?
    package let document: Data

    package init(configurationID: String?, document: Data) {
        self.configurationID = configurationID
        self.document = document
    }
}

package protocol RunConfigurationDocumentMutating: Sendable {
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

package struct ProjectToolchainSelection: Codable, Equatable, Sendable {
    package var javaHomePath = ""
    package var mavenExecutablePath = ""
    package var mavenJavaHomePath = ""

    package init(
        javaHomePath: String = "",
        mavenExecutablePath: String = "",
        mavenJavaHomePath: String = ""
    ) {
        self.javaHomePath = javaHomePath
        self.mavenExecutablePath = mavenExecutablePath
        self.mavenJavaHomePath = mavenJavaHomePath
    }
}

package protocol RunConfigurationOperations: Sendable {
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
    func saveEditorChanges(
        _ options: RunOptions,
        toolchain: ProjectToolchainSelection,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws
    func createConfiguration(_ draft: RunConfigurationDraft, at projectURL: URL) throws -> String
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws
}

package extension RunConfigurationOperations {
    func saveEditorChanges(
        _: RunOptions,
        toolchain _: ProjectToolchainSelection,
        configurationID _: String,
        scope _: RunConfigurationSaveScope,
        at _: URL
    ) throws {
        throw RunConfigurationEditorSaveFailure(
            stage: .prepare,
            message: "Run configuration editor saving is unavailable."
        )
    }
}
