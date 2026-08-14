import Combine
import Foundation

struct WorkspaceLanguageServerEnablement {
    private(set) var enabledProviderIDs: Set<String> = []

    func isDisabled(_ providerID: String) -> Bool {
        !enabledProviderIDs.contains(providerID)
    }

    mutating func setEnabled(_ enabled: Bool, providerID: String) {
        if enabled {
            enabledProviderIDs.insert(providerID)
        } else {
            enabledProviderIDs.remove(providerID)
        }
    }

    mutating func reset() {
        enabledProviderIDs.removeAll()
    }
}

/// Owns language-provider selection and workspace-scoped language-server UI state.
/// Protocol/session ownership remains in LanguageToolingSessionManager; this model
/// coordinates the feature without exposing that workflow to views.
@MainActor
final class LanguageToolingFeatureModel: ObservableObject {
    @Published private(set) var catalog: LanguageProviderCatalog
    @Published private(set) var catalogSnapshot: LanguageProviderCatalogSnapshot
    @Published private var enablement = WorkspaceLanguageServerEnablement()
    private(set) var startupFailures: [String: String] = [:]

    private let catalogSource: any LanguageProviderCatalogSource
    private let sessions: LanguageToolingSessionManager
    private let runtimeFeature: RuntimeSettingsFeatureModel
    private let settings: AppSettings
    private let projectRuntimeService: ProjectRuntimeService
    private var documentsProvider: (@MainActor () -> [EditorDocument])?
    private var workspaceProvider: (@MainActor () -> URL?)?
    private var activateDocument: (@MainActor (EditorDocument) -> Bool)?
    private var notify: (@MainActor (String) -> Void)?

    init(
        catalogSource: any LanguageProviderCatalogSource,
        catalogSnapshot: LanguageProviderCatalogSnapshot,
        sessions: LanguageToolingSessionManager,
        runtimeFeature: RuntimeSettingsFeatureModel,
        settings: AppSettings,
        projectRuntimeService: ProjectRuntimeService
    ) {
        self.catalogSource = catalogSource
        self.catalogSnapshot = catalogSnapshot
        catalog = catalogSnapshot.catalog
        self.sessions = sessions
        self.runtimeFeature = runtimeFeature
        self.settings = settings
        self.projectRuntimeService = projectRuntimeService
    }

    func configure(
        documentsProvider: @escaping @MainActor () -> [EditorDocument],
        workspaceProvider: @escaping @MainActor () -> URL?,
        activateDocument: @escaping @MainActor (EditorDocument) -> Bool,
        notify: @escaping @MainActor (String) -> Void
    ) {
        self.documentsProvider = documentsProvider
        self.workspaceProvider = workspaceProvider
        self.activateDocument = activateDocument
        self.notify = notify
    }

    func resetWorkspaceState() {
        enablement.reset()
        startupFailures.removeAll()
    }

    func reloadCatalog(for workspaceURL: URL?) {
        let snapshot = catalogSource.load(workspaceURL: workspaceURL)
        catalogSnapshot = snapshot
        catalog = snapshot.catalog
        sessions.updateCatalog(snapshot.catalog)
    }

    func isDisabled(_ providerID: String) -> Bool {
        enablement.isDisabled(providerID)
    }

    func setEnabled(_ enabled: Bool, providerID: String) {
        enablement.setEnabled(enabled, providerID: providerID)
        if enabled {
            synchronizeOpenDocuments(providerID: providerID)
        } else {
            sessions.recordLanguageServerLog(
                providerID: providerID,
                level: .warning,
                message: "Language server disabled in this workspace",
                detail: "Manual stop"
            )
            sessions.stopLanguageServer(providerID: providerID)
        }
    }

    func toolConfigurationDidChange(providerID: String) {
        startupFailures[providerID] = nil
        sessions.stopLanguageServer(providerID: providerID)
        sessions.recordLanguageServerLog(
            providerID: providerID,
            level: .info,
            message: "Language server tool configuration changed",
            detail: isDisabled(providerID)
                ? "Configuration saved; language server remains disabled"
                : "Restarting enabled language server"
        )
        guard !isDisabled(providerID) else { return }
        synchronizeOpenDocuments(providerID: providerID)
    }

    func selectJavaJDK(_ path: String) {
        settings.javaLanguageServerJDKPath = path
        toolConfigurationDidChange(providerID: "java")
    }

    func markActivationSucceeded(providerID: String) {
        startupFailures[providerID] = nil
    }

    func markActivationFailed(providerID: String, descriptor: LanguageProviderDescriptor, error: Error) {
        let message = error.localizedDescription
        guard startupFailures[providerID] != message else { return }
        startupFailures[providerID] = message
        sessions.recordLanguageServerLog(
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
