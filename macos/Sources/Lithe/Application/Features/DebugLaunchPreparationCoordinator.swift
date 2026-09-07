import Foundation
import LitheCoreContracts

/// Resolves the inputs required before a generic debug feature can start.
///
/// The coordinator holds the application actions it needs (saving a dirty
/// document, reopening the Debug tool window) rather than receiving them as
/// per-call closures.
@MainActor
final class DebugLaunchPreparationCoordinator {
    enum PreparationError: LocalizedError {
        case portUnavailable(Int)

        var errorDescription: String? {
            switch self {
            case .portUnavailable(let port):
                return "Port \(port) is already in use. Stop the process using it or change server.port in the Run configuration."
            }
        }
    }

    private let notify: @MainActor (String) -> Void
    private weak var actions: (any DebugWorkflowActions)?

    init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }

    /// Held weakly: the application aggregate owns this coordinator.
    func connect(actions: any DebugWorkflowActions) {
        self.actions = actions
    }

    func saveDirtyDocumentIfNeeded(_ document: EditorDocument?) -> Bool {
        guard let document, document.isDirty else { return true }
        guard let actions else { return false }
        do {
            let previousText = document.savedText
            try actions.save(document)
            actions.recordSave(document, previousText: previousText)
            return true
        } catch {
            notify("Could not save \(document.url.lastPathComponent)")
            return false
        }
    }

    func start(
        configuration: DebugLaunchConfiguration,
        launch: () -> Bool,
        errorMessage: String?
    ) -> Bool {
        guard launch() else {
            notify(errorMessage ?? "Could not start debugging")
            actions?.showDebugToolWindow()
            return false
        }
        return true
    }

    func prepare(
        provider: LanguageProviderDescriptor,
        fileURL: URL,
        workspaceURL: URL,
        runFeature: RunFeatureModel,
        resolver: DebugLaunchConfigurationResolver,
        portChecker: any DebugPortAvailabilityChecking,
        resolveJavaTarget: @escaping () async throws -> JavaDebugLaunchTarget?
    ) async throws -> DebugLaunchConfiguration {
        if provider.id == "java",
           let selected = runFeature.selectedConfiguration,
           let port = runFeature.configuredServerPort(for: selected),
           !portChecker.isPortAvailable(port) {
            throw PreparationError.portUnavailable(port)
        }

        let javaTarget = provider.id == "java" ? try await resolveJavaTarget() : nil
        return try resolver.resolve(
            provider: provider,
            documentURL: fileURL,
            workspaceURL: workspaceURL,
            configurations: runFeature.configurations,
            selectedConfiguration: runFeature.selectedConfiguration,
            javaTarget: javaTarget,
            options: { [runFeature] in runFeature.options(for: $0) }
        )
    }
}
