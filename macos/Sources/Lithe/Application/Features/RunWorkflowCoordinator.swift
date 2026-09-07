import Foundation
import LitheApplicationKernel
import LitheDebugModule
import LitheExecutionModule
import LitheModuleAPI

/// Identifies one opening of one workspace for stale-run protection.
struct WorkspaceIdentity: Equatable {
    let url: URL
    let generation: Int
}

/// An action deferred until the run feature owns the current workspace snapshot.
struct PendingRunAction: Equatable {
    enum Kind: Equatable {
        case run
        case debug
        case startConfiguration(RunConfiguration)
        case runAllServices
        case restart
    }

    let kind: Kind
    let identity: WorkspaceIdentity
}

enum RunProjectReadiness: Equatable {
    case ready
    case waitingForSnapshot(identity: WorkspaceIdentity)
    case stale
}

enum RunConfigurationReadiness {
    case ready(RunConfiguration)
    case needsGeneration
    case unavailable
}

enum DebugSourceResolution {
    case resolved(URL)
    case currentFileUnavailable
    case javaSourceUnavailable(String)
    case unsupported(String)
}

enum DebugProviderReadiness {
    case ready
    case unsupported(String)
}

/// Owns run-entry readiness and the deferred-action queue.
///
/// The coordinator holds `pendingRunAction` rather than the application shell so
/// defer/resume is a single owner's decision. Entry points capture a
/// `WorkspaceIdentity` before their first await and pass it back in, which is
/// what lets a project switch — or a close and reopen of the same path — be
/// reported as `.stale` instead of resuming into the wrong opening.
@MainActor
final class RunWorkflowCoordinator {
    /// The action waiting for a workspace snapshot, if any.
    ///
    /// Not `@Published`: the application shell relays its own change
    /// notification through `onPendingActionChange` so a defer/resume is visible
    /// to observers without loading a feature.
    private(set) var pendingAction: PendingRunAction?

    private let pluginCatalog: ValidatedPluginCatalog
    private let moduleRuntime: ModuleRuntime
    private let notify: @MainActor (String) -> Void
    private let onPendingActionChange: @MainActor () -> Void
    private weak var actions: (any RunWorkflowActions)?

    init(
        pluginCatalog: ValidatedPluginCatalog,
        moduleRuntime: ModuleRuntime,
        notify: @escaping @MainActor (String) -> Void,
        onPendingActionChange: @escaping @MainActor () -> Void = {}
    ) {
        self.pluginCatalog = pluginCatalog
        self.moduleRuntime = moduleRuntime
        self.notify = notify
        self.onPendingActionChange = onPendingActionChange
    }

    /// Connects the entry points a deferred action resumes into.
    ///
    /// Held weakly: the application aggregate owns this coordinator, and the
    /// resume path must not keep it alive past a workspace teardown.
    func connect(actions: any RunWorkflowActions) {
        self.actions = actions
    }

    func configurationReadiness(
        status: ProjectRunConfigurationStatus,
        selected: RunConfiguration?
    ) -> RunConfigurationReadiness {
        guard status == .ready else { return .needsGeneration }
        guard let selected else { return .unavailable }
        return .ready(selected)
    }

    func reapplySelectedConfiguration(_ runFeature: RunFeatureModel) {
        guard let selected = runFeature.selectedConfiguration else { return }
        runFeature.select(selected)
    }

    func debugConfiguration(
        selected: RunConfiguration,
        activeDocumentText: String?,
        configurations: [RunConfiguration]
    ) -> RunConfiguration {
        DebugLaunchSourceResolver().configurationForDebug(
            selected: selected,
            activeDocumentText: activeDocumentText,
            configurations: configurations
        )
    }

    func sourceURLForDebug(
        configuration: RunConfiguration,
        activeDocument: EditorDocument?,
        projectFiles: [URL],
        workspaceURL: URL
    ) -> URL? {
        if configuration.usesCurrentEditorFile {
            return activeDocument?.url
        }
        guard configuration.kind.capabilities.contains(.jdwpDebug) else {
            return nil
        }
        return DebugLaunchSourceResolver().resolve(
            configuration: configuration,
            activeDocumentURL: activeDocument?.url,
            projectFiles: projectFiles,
            workspaceURL: workspaceURL
        )
    }

    func resolveDebugSource(
        configuration: RunConfiguration,
        activeDocument: EditorDocument?,
        projectFiles: [URL],
        workspaceURL: URL
    ) -> DebugSourceResolution {
        guard let sourceURL = sourceURLForDebug(
            configuration: configuration,
            activeDocument: activeDocument,
            projectFiles: projectFiles,
            workspaceURL: workspaceURL
        ) else {
            if configuration.usesCurrentEditorFile {
                return .currentFileUnavailable
            }
            if configuration.kind.capabilities.contains(.jdwpDebug) {
                return .javaSourceUnavailable(configuration.name)
            }
            return .unsupported(configuration.name)
        }
        return .resolved(sourceURL)
    }

    func debugProviderReadiness(
        sourceURL: URL,
        supportsDebugAdapter: Bool
    ) -> DebugProviderReadiness {
        guard supportsDebugAdapter else {
            return .unsupported(sourceURL.lastPathComponent)
        }
        return .ready
    }

    func activateLanguageRunExtension(
        _ support: LanguageSupportDeclaration,
        runFeature: RunFeatureModel
    ) async -> Bool {
        guard support.executionModuleID != nil else {
            notify("\(support.displayName) does not provide project execution")
            return false
        }
        do {
            let value = try await moduleRuntime.activateCapability(
                .languageExecutionExtension(support.id)
            )
            guard let provider = value as? any LanguageRunExtensionProviding,
                  runFeature.registerLanguageRunExtension(provider, support: support) else {
                notify("\(support.displayName) returned an invalid execution provider")
                return false
            }
            return true
        } catch {
            notify(error.localizedDescription)
            return false
        }
    }

    func activateLanguageRunExtensionIfNeeded(
        for configuration: RunConfiguration,
        currentFileURL: URL?,
        runFeature: RunFeatureModel
    ) async -> Bool {
        let support = languageSupport(
            for: configuration,
            currentFileURL: currentFileURL,
            languageSupportForFile: { [pluginCatalog] fileURL in
                pluginCatalog.languageSupport(for: fileURL)?.declaration
            },
            languageSupportForProvider: { [pluginCatalog] providerID in
                pluginCatalog.languageSupports[providerID]?.declaration
            }
        )
        guard let support else { return true }
        return await activateLanguageRunExtension(support, runFeature: runFeature)
    }

    func languageSupport(
        for configuration: RunConfiguration,
        currentFileURL: URL?,
        languageSupportForFile: (URL) -> LanguageSupportDeclaration?,
        languageSupportForProvider: (String) -> LanguageSupportDeclaration?
    ) -> LanguageSupportDeclaration? {
        if configuration.usesCurrentEditorFile {
            guard let currentFileURL else { return nil }
            return languageSupportForFile(currentFileURL)
        }
        return languageSupportForProvider(configuration.kind.providerID)
    }

    func saveDirtyCurrentFileIfNeeded(
        configuration: RunConfiguration,
        document: EditorDocument?,
        saving: any EditorDocumentSaving
    ) -> Bool {
        guard configuration.usesCurrentEditorFile,
              let document,
              document.isDirty else {
            return true
        }
        do {
            let previousText = document.savedText
            try saving.save(document)
            saving.recordSave(document, previousText: previousText)
            return true
        } catch {
            notify("Could not save \(document.url.lastPathComponent)")
            return false
        }
    }

    /// Brings the run feature up to the snapshot for a captured opening.
    ///
    /// When a newer snapshot is published but the run service still holds an
    /// older `.ready` inventory for this workspace, the snapshot callback owns
    /// the transition. Loading from the entry path would race that callback and
    /// let Restart proceed from a half-applied refresh.
    ///
    /// When the run service is not already ready for this workspace, the entry
    /// path applies the published scan itself (open-before-run, prune, tool
    /// window) so readiness does not wait on a callback that may never arrive.
    func ensureProjectReady(
        _ runFeature: RunFeatureModel,
        identity: WorkspaceIdentity,
        appliedSnapshotID: UUID?,
        appliedFiles: [URL],
        isCurrent: @escaping @MainActor (WorkspaceIdentity) -> Bool
    ) async -> RunProjectReadiness {
        guard isCurrent(identity) else { return .stale }
        if runFeature.isProjectReady(
            for: identity.url,
            snapshotID: appliedSnapshotID
        ) {
            return .ready
        }
        if appliedSnapshotID != nil,
           runFeature.hasReadyInventory(for: identity.url) {
            return .waitingForSnapshot(identity: identity)
        }
        await actions?.loadProject(
            at: identity.url,
            files: appliedFiles,
            snapshotID: appliedSnapshotID
        )
        guard isCurrent(identity) else { return .stale }
        if runFeature.isProjectReady(
            for: identity.url,
            snapshotID: appliedSnapshotID
        ) {
            return .ready
        }
        return .waitingForSnapshot(identity: identity)
    }

    /// Records an action for the opening the entry task captured, not whatever
    /// workspace happens to be current after an await.
    func deferAction(_ kind: PendingRunAction.Kind, for identity: WorkspaceIdentity) {
        setPendingAction(PendingRunAction(kind: kind, identity: identity))
    }

    func clearPendingAction(for identity: WorkspaceIdentity) {
        guard pendingAction?.identity == identity else { return }
        setPendingAction(nil)
    }

    /// Drops any deferred action, used when a workspace opens or closes.
    func resetPendingAction() {
        setPendingAction(nil)
    }

    /// Continues an action that arrived before the snapshot did. The workspace
    /// rebuild always finishes by applying a snapshot, so recording the intent is
    /// enough to resume without polling or waiting.
    ///
    /// A load for one opening must not clear a pending action that belongs to
    /// another: opening a project already cleared the old pending on the switch,
    /// and a stale callback arriving later would otherwise wipe the newly
    /// recorded intent.
    ///
    /// `snapshotID` is the scan this load just applied, not whatever the
    /// workspace holds now. Reading the current identity here would compare the
    /// run feature against a scan it has not consumed.
    func resumeDeferredAction(
        runFeature: RunFeatureModel,
        identity: WorkspaceIdentity,
        snapshotID: UUID?
    ) {
        guard let action = pendingAction,
              action.identity == identity,
              runFeature.isProjectReady(for: identity.url, snapshotID: snapshotID)
        else { return }
        setPendingAction(nil)
        performDeferredAction(action.kind)
    }

    func performDeferredAction(_ kind: PendingRunAction.Kind) {
        guard let actions else { return }
        switch kind {
        case .run:
            actions.runSelectedConfiguration()
        case .debug:
            actions.startDebugging()
        case .startConfiguration(let configuration):
            actions.startRunConfiguration(configuration)
        case .runAllServices:
            actions.runAllServiceConfigurations()
        case .restart:
            actions.restartSelectedRun()
        }
    }

    private func setPendingAction(_ action: PendingRunAction?) {
        guard pendingAction != action else { return }
        pendingAction = action
        onPendingActionChange()
    }
}
