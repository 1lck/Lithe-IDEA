import LitheModuleAPI
import Combine
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// Owns language-provider selection and workspace-scoped language-server UI state.
/// Protocol/session ownership remains in LanguageToolingSessionManager; this model
/// coordinates the feature without exposing that workflow to views.
@MainActor
final class LanguageToolingFeatureModel: ObservableObject {
    @Published private(set) var catalog: LanguageProviderCatalog
    @Published private(set) var catalogSnapshot: LanguageProviderCatalogSnapshot
    @Published private(set) var disabledProviderIDs: Set<String> = []
    @Published private(set) var projectPreparation: ProjectPreparationSnapshot?
    @Published private(set) var serverRuntimeSnapshot = LanguageServerRuntimeSnapshot()
    let projectUsage = LSPProjectUsageModel()
    let logs = LanguageServerLogsModel()
    private var preparationObservation: AnyCancellable?
    private var statusObservation: AnyCancellable?
    private(set) var startupFailures: [String: String] = [:]

    private let catalogSource: any LanguageProviderCatalogSource
    private let preferences: any WorkspaceLanguageServerPreferencesStoring
    private var workspaceURL: URL?
    private var sessionsProvider: @MainActor () -> LanguageToolingSessionManager?
    private var documentsProvider: (@MainActor () -> [EditorDocument])?
    private var activateDocument: (@MainActor (EditorDocument) -> Bool)?
    private var notify: (@MainActor (String) -> Void)?
    private var preparationCancellations: [String: @MainActor () -> Void] = [:]
    private var activationEpoch = UUID()
    private var activationGenerations: [String: UUID] = [:]

    struct ActivationToken: Equatable {
        let epoch: UUID
        let generation: UUID?
    }

    func activationToken(providerID: String) -> ActivationToken {
        ActivationToken(epoch: activationEpoch, generation: activationGenerations[providerID])
    }

    func registerPreparationCancellation(providerID: String, cancel: @escaping @MainActor () -> Void) {
        preparationCancellations[providerID] = cancel
    }

    private func prepareToStop(providerID: String) {
        activationGenerations[providerID] = UUID()
        preparationCancellations[providerID]?()
    }

    init(
        catalogSource: any LanguageProviderCatalogSource,
        catalogSnapshot: LanguageProviderCatalogSnapshot,
        preferences: any WorkspaceLanguageServerPreferencesStoring,
        sessionsProvider: @escaping @MainActor () -> LanguageToolingSessionManager?
    ) {
        self.catalogSource = catalogSource
        self.preferences = preferences
        self.catalogSnapshot = catalogSnapshot
        catalog = catalogSnapshot.catalog
        self.sessionsProvider = sessionsProvider
    }

    func configure(
        documentsProvider: @escaping @MainActor () -> [EditorDocument],
        activateDocument: @escaping @MainActor (EditorDocument) -> Bool,
        notify: @escaping @MainActor (String) -> Void
    ) {
        self.documentsProvider = documentsProvider
        self.activateDocument = activateDocument
        self.notify = notify
    }

    func configureSessions(
        provider: @escaping @MainActor () -> LanguageToolingSessionManager?
    ) {
        sessionsProvider = provider
    }

    func bindProjectPreparation(_ sessions: LanguageToolingSessionManager) {
        logs.bind(sessions)
        statusObservation = Publishers.CombineLatest(sessions.$languageServerStates, sessions.$languageServerInfos)
            .map { LanguageServerRuntimeSnapshot(states: $0, infos: $1) }
            .removeDuplicates().sink { [weak self] in self?.serverRuntimeSnapshot = $0 }
        preparationObservation = sessions.$projectPreparation.removeDuplicates().sink { [weak self] snapshot in
            self?.projectPreparation = snapshot
        }
    }

    func resetWorkspaceState() {
        activationEpoch = UUID()
        activationGenerations.removeAll()
        logs.reset()
        serverRuntimeSnapshot = LanguageServerRuntimeSnapshot()
        projectPreparation = nil
        startupFailures.removeAll()
    }

    func projectUsageRequest(workspaceURL: URL?, snapshotID: UUID?) -> LSPProjectUsageRequest {
        let providers = catalog.descriptors
            .filter { $0.capabilities.contains(.languageServer) && $0.languageServerLaunch != nil }
            .map {
                LSPProjectUsageRequest.Rule(target: .provider($0.id), fileExtensions: $0.fileExtensions,
                                            fileNames: $0.fileNames, fileNamePrefixes: $0.fileNamePrefixes)
            }
        let plugins = OfficialPluginCatalog.entries.map {
            LSPProjectUsageRequest.Rule(target: .plugin($0.id.rawValue), fileExtensions: Set($0.fileExtensions),
                                       fileNames: Set($0.projectFileNames))
        }
        return LSPProjectUsageRequest(workspaceURL: workspaceURL, snapshotID: snapshotID, rules: providers + plugins)
    }

    func projectUsageInput(workspaceURL: URL?, snapshot: WorkspaceSnapshot?) -> LSPProjectUsageInput {
        LSPProjectUsageInput(
            request: projectUsageRequest(workspaceURL: workspaceURL, snapshotID: snapshot?.id),
            files: snapshot?.files ?? []
        )
    }

    func reloadCatalog(for workspaceURL: URL?) {
        // Runtime/index resets also call resetWorkspaceState while Settings is
        // still visible. Only a workspace boundary invalidates the usage cache;
        // otherwise an unchanged .task(id:) would not reload the cleared value.
        projectUsage.reset()
        self.workspaceURL = workspaceURL?.standardizedFileURL
        // Restore preferences before workspace restoration can activate documents
        // or prewarm Java. Runtime resets must not erase explicit user choices.
        disabledProviderIDs = self.workspaceURL.map { preferences.disabledProviderIDs(for: $0) } ?? []
        resetWorkspaceState()
        let snapshot = catalogSource.load(workspaceURL: workspaceURL)
        catalogSnapshot = snapshot
        catalog = snapshot.catalog
        sessionsProvider()?.updateCatalog(snapshot.catalog)
    }

    /// Reloads the catalog after the installed plugins changed, keeping the
    /// workspace's preferences and the state of servers that are still running.
    func refreshCatalog() {
        let snapshot = catalogSource.load(workspaceURL: workspaceURL)
        guard snapshot.catalog.descriptors != catalog.descriptors else { return }
        catalogSnapshot = snapshot
        catalog = snapshot.catalog
        sessionsProvider()?.updateCatalog(snapshot.catalog)
    }

    func isDisabled(_ providerID: String) -> Bool {
        disabledProviderIDs.contains(providerID)
    }

    func setEnabled(_ enabled: Bool, providerID: String) {
        guard let workspaceURL else { return }
        if enabled {
            disabledProviderIDs.remove(providerID)
        } else {
            disabledProviderIDs.insert(providerID)
        }
        preferences.saveDisabledProviderIDs(disabledProviderIDs, for: workspaceURL)
        if enabled {
            synchronizeOpenDocuments(providerID: providerID)
        } else {
            prepareToStop(providerID: providerID)
            sessionsProvider()?.recordLanguageServerLog(
                providerID: providerID,
                level: .warning,
                message: L10n.string("Language server disabled in this workspace"),
                detail: L10n.string("Manual stop")
            )
            sessionsProvider()?.stopLanguageServer(providerID: providerID)
        }
    }

    func toolConfigurationDidChange(providerID: String) {
        prepareToStop(providerID: providerID)
        startupFailures[providerID] = nil
        sessionsProvider()?.stopLanguageServer(providerID: providerID)
        sessionsProvider()?.recordLanguageServerLog(
            providerID: providerID,
            level: .info,
            message: L10n.string("Language server tool configuration changed"),
            detail: L10n.string("Workspace language server preference preserved")
        )
    }

    /// Session-only controls leave the workspace's persistent enablement alone.
    func stop(providerID: String) {
        prepareToStop(providerID: providerID)
        sessionsProvider()?.stopLanguageServer(providerID: providerID)
    }

    func restart(providerID: String) {
        guard !isDisabled(providerID), let workspaceURL,
              let descriptor = catalog.descriptors.first(where: {
                  $0.id == providerID && $0.capabilities.contains(.languageServer)
              }), let sessions = sessionsProvider() else { return }
        stop(providerID: providerID)
        startupFailures[providerID] = nil
        let documents = (documentsProvider?() ?? []).filter { catalog.provider(for: $0.url)?.id == providerID }
        if documents.isEmpty {
            // A prewarmed server can outlive its last editor tab. Restart that
            // same provider instead of silently turning Restart into Stop.
            do { try sessions.startLanguageServer(providerID: providerID, rootURL: workspaceURL) }
            catch { markActivationFailed(providerID: providerID, descriptor: descriptor, error: error) }
        } else {
            for document in documents { _ = activateDocument?(document) }
        }
    }

    func markActivationSucceeded(providerID: String) {
        startupFailures[providerID] = nil
    }

    func markActivationFailed(providerID: String, descriptor: LanguageProviderDescriptor, error: Error) {
        // A failure is reported only while the server is still wanted. Teardown
        // cancels activation when the module graph is rebuilt, and the user may
        // disable the server before a pending activation fails; neither is a
        // startup failure to retry or something to report.
        guard !error.isCancellation, !isDisabled(providerID) else { return }
        let message = error.localizedDescription
        guard startupFailures[providerID] != message else { return }
        startupFailures[providerID] = message
        sessionsProvider()?.recordLanguageServerLog(
            providerID: providerID,
            level: .error,
            message: L10n.string("Language server activation failed"),
            detail: message
        )
        notify?("Could not start \(descriptor.displayName) language server: \(message)")
    }

    func shouldRetryCandidate(providerID: String) -> Bool {
        startupFailures[providerID] != nil
    }

    private func synchronizeOpenDocuments(providerID: String) {
        for document in documentsProvider?() ?? [] where catalog.provider(for: document.url)?.id == providerID {
            _ = activateDocument?(document)
        }
    }
}
