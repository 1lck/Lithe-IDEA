import Combine
import Foundation
import LitheLanguageIntelligenceModule

/// Owns language-provider selection and workspace-scoped language-server UI state.
/// Protocol/session ownership remains in LanguageToolingSessionManager; this model
/// coordinates the feature without exposing that workflow to views.
@MainActor
final class LanguageToolingFeatureModel: ObservableObject {
    @Published private(set) var catalog: LanguageProviderCatalog
    @Published private(set) var catalogSnapshot: LanguageProviderCatalogSnapshot
    @Published private(set) var disabledProviderIDs: Set<String> = []
    private(set) var startupFailures: [String: String] = [:]

    private let catalogSource: any LanguageProviderCatalogSource
    private let preferences: any WorkspaceLanguageServerPreferencesStoring
    private var workspaceURL: URL?
    private var sessionsProvider: @MainActor () -> LanguageToolingSessionManager?
    private var documentsProvider: (@MainActor () -> [EditorDocument])?
    private var activateDocument: (@MainActor (EditorDocument) -> Bool)?
    private var notify: (@MainActor (String) -> Void)?

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

    func resetWorkspaceState() {
        startupFailures.removeAll()
    }

    func reloadCatalog(for workspaceURL: URL?) {
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
            sessionsProvider()?.recordLanguageServerLog(
                providerID: providerID,
                level: .warning,
                message: "Language server disabled in this workspace",
                detail: "Manual stop"
            )
            sessionsProvider()?.stopLanguageServer(providerID: providerID)
        }
    }

    func toolConfigurationDidChange(providerID: String) {
        startupFailures[providerID] = nil
        sessionsProvider()?.stopLanguageServer(providerID: providerID)
        sessionsProvider()?.recordLanguageServerLog(
            providerID: providerID,
            level: .info,
            message: "Language server tool configuration changed",
            detail: "Workspace language server preference preserved"
        )
    }

    func markActivationSucceeded(providerID: String) {
        startupFailures[providerID] = nil
    }

    func markActivationFailed(providerID: String, descriptor: LanguageProviderDescriptor, error: Error) {
        let message = error.localizedDescription
        guard startupFailures[providerID] != message else { return }
        startupFailures[providerID] = message
        sessionsProvider()?.recordLanguageServerLog(
            providerID: providerID,
            level: .error,
            message: "Language server activation failed",
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
