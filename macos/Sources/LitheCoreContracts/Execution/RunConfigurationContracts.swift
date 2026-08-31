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

/// How complete the workspace file inventory a run service holds is.
///
/// Being bound to a workspace URL and holding a complete file inventory are
/// different things. Reading an existing configuration only needs the URL, while
/// generating one scans the inventory, so a provisional inventory would write a
/// configuration that omits entry points the workspace actually contains.
///
/// This describes the inventory only. Whether the configuration on disk is
/// readable is `ProjectRunConfigurationStatus`, and the two must stay separate:
/// a broken `generated.json` has to remain regenerable.
package enum ProjectLoadState: Equatable, Sendable {
    case idle
    /// A load is in flight. Entering this state before the load's first
    /// suspension point is what stops a cancelled or superseded load from
    /// leaving the previous `ready` inventory in place.
    case loading(workspace: URL)
    /// Bound to the workspace, but the file inventory is provisional because the
    /// workspace snapshot has not been applied yet. Existing configuration can be
    /// read; generation must wait.
    case bound(workspace: URL)
    /// The inventory came from the identified workspace snapshot, so generation
    /// can scan it safely.
    case ready(workspace: URL, snapshotID: UUID)

    /// Whether the inventory matches `snapshotID` for `workspace`, and is
    /// therefore the current, complete inventory.
    ///
    /// Comparing the snapshot as well as the workspace is what rejects a
    /// superseded snapshot of the same workspace: a refresh publishes a new
    /// snapshot before the run service consumes it, and scanning the previous
    /// inventory would miss entry points the refresh added.
    package func isReady(for workspace: URL, snapshotID: UUID?) -> Bool {
        guard let snapshotID,
              case .ready(let boundWorkspace, let boundSnapshotID) = self
        else { return false }
        return boundWorkspace == workspace.standardizedFileURL && boundSnapshotID == snapshotID
    }

    /// Whether a complete inventory for `workspace` is already applied, whichever
    /// snapshot produced it.
    ///
    /// A refresh publishes its snapshot before this state consumes it, so in that
    /// window the inventory is complete but superseded. Distinguishing it from a
    /// provisional or foreign binding is what lets a caller leave the transition
    /// to the snapshot callback instead of loading the scan itself.
    package func hasReadyInventory(for workspace: URL) -> Bool {
        guard case .ready(let boundWorkspace, _) = self else { return false }
        return boundWorkspace == workspace.standardizedFileURL
    }
}

package enum RunConfigurationGenerationState: Equatable, Sendable {
    case idle
    /// The request arrived before the workspace snapshot was applied, so there
    /// was no complete file inventory to identify. Nothing failed, and nothing
    /// was written.
    case projectNotReady
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
    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?,
        mavenContext: MavenLaunchContext?
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
    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?,
        mavenContext _: MavenLaunchContext?
    ) throws -> SharedLaunchPlan {
        try launchPlan(
            at: projectURL,
            configurationID: configurationID,
            currentFile: currentFile,
            classPath: classPath,
            debugPort: debugPort
        )
    }

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
