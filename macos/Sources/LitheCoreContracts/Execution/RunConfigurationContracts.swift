import LitheModuleAPI
import Foundation

/// Revokes user-document and native-state publication when generation loses its owner.
package final class RunConfigurationGenerationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    package init() {}
    package func invalidate() { lock.lock(); current = false; lock.unlock() }
    package var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return current }
    package func check() throws { if !isCurrent { throw CancellationError() } }
}

/// An inert per-operation tool choice. Core verifies files and versions before use.
package enum FixedToolchainSelection: Codable, Hashable, Sendable {
    case installation(home: String)
    case executable(path: String)
    private enum CodingKeys: String, CodingKey { case home, executable }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one explicit tool choice"))
        }
        if values.contains(.home) { self = .installation(home: try values.decode(String.self, forKey: .home)) }
        else { self = .executable(path: try values.decode(String.self, forKey: .executable)) }
    }
    package func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .installation(let home): try values.encode(home, forKey: .home)
        case .executable(let path): try values.encode(path, forKey: .executable)
        }
    }
}

/// Portable user choices stored apart from the current target selector.
package struct BuildProviderRunOptions: Codable, Hashable, Sendable {
    package var runtimeArguments: [String]
    /// Empty clears an inherited entrypoint without naming a runtime.
    package var entrypoint: String
    package var options: [String: ToolingJSONValue]
    package var tools: [String: FixedToolchainSelection?]
    package init(runtimeArguments: [String] = [], entrypoint: String = "", options: [String: ToolingJSONValue] = [:],
                 tools: [String: FixedToolchainSelection?] = [:]) {
        self.runtimeArguments = runtimeArguments; self.entrypoint = entrypoint; self.options = options
        self.tools = tools
    }
    private enum CodingKeys: CodingKey { case runtimeArguments, entrypoint, options, tools }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runtimeArguments = try values.decodeIfPresent([String].self, forKey: .runtimeArguments) ?? []
        entrypoint = try values.decodeIfPresent(String.self, forKey: .entrypoint) ?? ""
        options = try values.decodeIfPresent([String: ToolingJSONValue].self, forKey: .options) ?? [:]
        tools = try values.decodeIfPresent([String: FixedToolchainSelection?].self, forKey: .tools) ?? [:]
    }
}

/// A current model target matched to a public run declaration; no tool semantics.
package struct RunProviderConfiguration: Codable, Equatable, Sendable {
    package let projectPath: String
    package let name: String
    package let reference: BuildProviderRunReference
    package init(projectPath: String, name: String, reference: BuildProviderRunReference) {
        self.projectPath = projectPath; self.name = name; self.reference = reference
    }
}

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
    /// Toolchain requirement ID the diagnostic is about, such as `project-node`.
    package let toolchain: String?

    package init(configurationID: String?, code: String, message: String, toolchain: String? = nil) {
        self.configurationID = configurationID
        self.code = code
        self.message = message
        self.toolchain = toolchain
    }

    package var id: String { [configurationID, code, message].compactMap { $0 }.joined(separator: ":") }
}

package struct ProjectRunConfigurationInspection: Equatable, Sendable {
    package let status: ProjectRunConfigurationStatus
    /// Saved tasks can be ready while this process still needs to detect other entries.
    package let requiresGeneration: Bool
    package let diagnostics: [RunConfigurationDiagnostic]
    package var recoveryAction: RunConfigurationRecoveryAction = .none
    package var recoveryPath: String? = nil

    package init(
        status: ProjectRunConfigurationStatus,
        diagnostics: [RunConfigurationDiagnostic],
        recoveryAction: RunConfigurationRecoveryAction = .none,
        recoveryPath: String? = nil,
        requiresGeneration: Bool = false
    ) {
        self.status = status
        self.requiresGeneration = requiresGeneration
        self.diagnostics = diagnostics
        self.recoveryAction = recoveryAction
        self.recoveryPath = recoveryPath
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

    /// Whether the run documents of `workspace` have been read. Unlike `hasReadyInventory`, a project without generated
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

    package init(
        configurations: [EffectiveRunConfiguration],
        diagnostics: [RunConfigurationDiagnostic],
        defaultConfigurationID: String?
    ) {
        self.configurations = configurations
        self.diagnostics = diagnostics
        self.defaultConfigurationID = defaultConfigurationID
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
            L10n.string("Could not prepare the run configuration: \(message)")
        case .write:
            L10n.string("Could not write the run configuration: \(message)")
        case .reload:
            L10n.string("Changes were saved, but Lithe could not reload them: \(message)")
        }
    }
}

package struct RunConfigurationGenerationResult: Sendable {
    package let entryCount: Int
    package init(entryCount: Int) { self.entryCount = entryCount }
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
}

/// Core resolves document layers without assembling the provider's command line.
package struct ProviderLaunchInputs: Decodable, Equatable, Sendable {
    package let reference: BuildProviderRunReference?
    package let buildSystemID: String
    package let provider: String
    package let projectPath: String
    package let launchOptions: BuildLaunchOptions
    package let optionOverrides: [String: ToolingJSONValue]
    package let tools: [String: FixedToolchainSelection]

    /// Saved applications carry opaque Provider arguments from protocol 4.
    /// Reclassifying them as opt-in version-10 launch options breaks old SDKs.
    package var opaqueReferenceArguments: [String]? {
        guard let reference, (reference.execution ?? .application) == .application,
              launchOptions.execution == .application, launchOptions.runtimeArguments.isEmpty,
              launchOptions.environment.isEmpty, launchOptions.workingDirectory == nil,
              launchOptions.entrypoint == nil, launchOptions.debug == nil,
              launchOptions.arguments == reference.userArguments else { return nil }
        return reference.userArguments
    }

    package init(buildSystemID: String, provider: String, projectPath: String, launchOptions: BuildLaunchOptions,
                 optionOverrides: [String: ToolingJSONValue] = [:], reference: BuildProviderRunReference? = nil,
                 tools: [String: FixedToolchainSelection] = [:]) {
        self.reference = reference
        self.buildSystemID = buildSystemID; self.provider = provider; self.projectPath = projectPath
        self.launchOptions = launchOptions; self.optionOverrides = optionOverrides
        self.tools = tools
    }

    private enum CodingKeys: CodingKey { case reference, buildSystemID, provider, projectPath, launchOptions, optionOverrides, tools }
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reference = try values.decodeIfPresent(BuildProviderRunReference.self, forKey: .reference)
        buildSystemID = try values.decode(String.self, forKey: .buildSystemID)
        provider = try values.decode(String.self, forKey: .provider)
        projectPath = try values.decode(String.self, forKey: .projectPath)
        launchOptions = try values.decode(BuildLaunchOptions.self, forKey: .launchOptions)
        optionOverrides = try values.decodeIfPresent([String: ToolingJSONValue].self, forKey: .optionOverrides) ?? [:]
        tools = try values.decodeIfPresent([String: FixedToolchainSelection].self, forKey: .tools) ?? [:]
    }
}

package protocol RunConfigurationOperations: Sendable {
    func providerLaunchInputs(at projectURL: URL, configurationID: String, providerRoot: String) throws -> ProviderLaunchInputs
    func saveBuildProviderConfiguration(_ reference: BuildProviderRunReference, name: String, at projectURL: URL) throws -> String
    /// `checkFingerprint: false` validates the documents without reading project
    /// inputs. `providerRuns` is the current Provider snapshot; `nil` skips the
    /// staleness comparison, an empty list compares against "no Provider runs".
    func inspect(
        at projectURL: URL,
        checkFingerprint: Bool,
        providerRuns: [RunProviderConfiguration]?
    ) -> ProjectRunConfigurationInspection
    func generate(
        at projectURL: URL,
        providerRuns: [RunProviderConfiguration]?,
        lease: RunConfigurationGenerationLease
    ) throws -> RunConfigurationGenerationResult
    func resolve(
        at projectURL: URL,
        toolchainCandidates: [ProjectToolchainCandidate]
    ) throws -> RunConfigurationResolution
    func launchPlan(at projectURL: URL, configurationID: String) throws -> SharedLaunchPlan
    func saveEditorChanges(
        _ options: RunOptions,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws
}

package extension RunConfigurationOperations {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection {
        inspect(at: projectURL, checkFingerprint: true, providerRuns: nil)
    }

    /// Checks generated facts against the current Provider snapshot without hashing source files.
    func inspectProviderGeneration(at projectURL: URL, providerRuns: [RunProviderConfiguration]) -> ProjectRunConfigurationInspection {
        inspect(at: projectURL, checkFingerprint: false, providerRuns: providerRuns)
    }

    func generate(at projectURL: URL, providerRuns: [RunProviderConfiguration]?) throws -> RunConfigurationGenerationResult {
        try generate(at: projectURL, providerRuns: providerRuns, lease: RunConfigurationGenerationLease())
    }

    func providerLaunchInputs(at projectURL: URL, configurationID: String, providerRoot: String) throws -> ProviderLaunchInputs {
        throw RunConfigurationOperationFailure(message: L10n.string("Load the current build model and enable its provider before running this configuration."))
    }

    func saveBuildProviderConfiguration(_: BuildProviderRunReference, name: String, at _: URL) throws -> String {
        throw RunConfigurationOperationFailure(message: L10n.string("Saving build provider run configurations is unavailable."))
    }

    func saveEditorChanges(
        _: RunOptions,
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
