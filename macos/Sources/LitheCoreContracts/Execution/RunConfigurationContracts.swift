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
    /// Toolchain requirement ID the diagnostic is about, such as `project-jdk`.
    package let toolchain: String?

    package init(configurationID: String?, code: String, message: String, toolchain: String? = nil) {
        self.configurationID = configurationID
        self.code = code
        self.message = message
        self.toolchain = toolchain
    }

    package var id: String { [configurationID, code, message].compactMap { $0 }.joined(separator: ":") }
}

package extension Array where Element == RunConfigurationDiagnostic {
    /// Core's requirement checks for one toolchain, such as a JDK older than the
    /// project requires. Without `configurationID`, every configuration's result
    /// counts, because project defaults apply to all of them.
    func toolchainRequirementMessages(for toolchain: String, configurationID: String? = nil) -> [String] {
        let codes: Set<String> = ["missingToolchain", "toolchainVersionMismatch", "toolchainVendorMismatch"]
        var seen = Set<String>()
        return filter { diagnostic in
            codes.contains(diagnostic.code)
                && diagnostic.toolchain == toolchain
                && (configurationID == nil || diagnostic.configurationID == configurationID)
        }
        .map(\.message)
        .filter { seen.insert($0).inserted }
    }
}

package struct ProjectRunConfigurationInspection: Equatable, Sendable {
    package let status: ProjectRunConfigurationStatus
    package let diagnostics: [RunConfigurationDiagnostic]
    package var recoveryAction: RunConfigurationRecoveryAction = .none
    package var recoveryPath: String? = nil
    /// Project defaults saved in the machine-local run layer. `nil` means that
    /// layer holds no defaults yet, which differs from explicitly automatic ones.
    package var projectToolchain: ProjectToolchainSelection? = nil

    package init(
        status: ProjectRunConfigurationStatus,
        diagnostics: [RunConfigurationDiagnostic],
        recoveryAction: RunConfigurationRecoveryAction = .none,
        recoveryPath: String? = nil,
        projectToolchain: ProjectToolchainSelection? = nil
    ) {
        self.status = status
        self.diagnostics = diagnostics
        self.recoveryAction = recoveryAction
        self.recoveryPath = recoveryPath
        self.projectToolchain = projectToolchain
    }
}

package enum ProjectLoadState: Equatable, Sendable {
    case idle
    case loading(workspace: URL)
    case bound(workspace: URL)
    case ready(workspace: URL, snapshotID: UUID)
    case failed(workspace: URL, message: String)

    package func isReady(for workspace: URL, snapshotID: UUID? = nil) -> Bool {
        guard case .ready(let boundWorkspace, let boundSnapshotID) = self,
              boundWorkspace == workspace.standardizedFileURL else { return false }
        return snapshotID.map { $0 == boundSnapshotID } ?? true
    }

    package func hasReadyInventory(for workspace: URL) -> Bool {
        guard case .ready(let boundWorkspace, _) = self else { return false }
        return boundWorkspace == workspace.standardizedFileURL
    }

    /// Whether the run documents of `workspace`, including its project toolchain,
    /// have been read. Unlike `hasReadyInventory`, a project without generated
    /// configurations counts once inspection bound it.
    package func hasLoadedDocuments(for workspace: URL) -> Bool {
        switch self {
        case .bound(let boundWorkspace), .ready(let boundWorkspace, _):
            boundWorkspace == workspace.standardizedFileURL
        case .idle, .loading, .failed:
            false
        }
    }
}

/// Outcome of asking JDT which classes can be launched, taken before a
/// generation. Whether a class is launchable is JDT's answer; Lithe never
/// derives entry points from source text.
///
/// Note: 入口点归属见 .agents/notes/implemented/architecture/2026-09-21-java-entrypoints-owned-by-jdt.md
package enum JavaEntrypointDiscovery: Equatable, Sendable {
    /// The workspace has no Java sources, so there is nothing to ask.
    case notJava
    case discovered(JavaEntrypoints)
    /// The Java service is starting or still importing the project.
    case pending
    case failed(String)

    /// JDT's answer, or `nil` so Core keeps the previous generation's entries.
    package var entrypoints: JavaEntrypoints? {
        if case .discovered(let entrypoints) = self { return entrypoints }
        return nil
    }
}

/// Where the Java entries shown in the Run list come from.
///
/// `ready` is JDT's current answer; `stale` shows the previous answer while the
/// Java service prepares the project; `loading` has no previous answer yet;
/// `failed` keeps the previous list and says why it could not refresh.
package enum JavaDiscoveryStatus: Equatable, Sendable {
    case idle
    case loading
    case ready
    case stale
    case failed(String)
}

package enum RunConfigurationGenerationState: Equatable, Sendable {
    case idle
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
    /// Saves project defaults without modifying any service or requiring generated configurations.
    func saveProjectToolchain(_ toolchain: ProjectToolchainSelection, at projectURL: URL) throws
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection
    /// `javaEntrypoints` is JDT's current answer; `nil` keeps the previous
    /// generation's Java entries while the Java service prepares the project.
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String],
        javaEntrypoints: JavaEntrypoints?
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
    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        javaLaunch: JavaDebugLaunchTarget?,
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
    func saveProjectToolchain(_: ProjectToolchainSelection, at _: URL) throws {
        throw RunConfigurationEditorSaveFailure(stage: .prepare, message: "Project environment saving is unavailable.")
    }
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

    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        javaLaunch _: JavaDebugLaunchTarget?,
        debugPort: Int?,
        mavenContext: MavenLaunchContext?
    ) throws -> SharedLaunchPlan {
        try launchPlan(
            at: projectURL,
            configurationID: configurationID,
            currentFile: currentFile,
            classPath: classPath,
            debugPort: debugPort,
            mavenContext: mavenContext
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
