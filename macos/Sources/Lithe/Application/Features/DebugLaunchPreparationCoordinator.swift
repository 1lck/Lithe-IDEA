import LitheModuleAPI
import Foundation
import LitheCoreContracts

/// Resolves the inputs required before a generic debug feature can start.
///
/// The coordinator holds the application actions it needs (saving a dirty
/// document, reopening the Debug tool window) rather than receiving them as
/// per-call closures.
@MainActor
final class DebugLaunchPreparationCoordinator {
    private let notify: @MainActor (String) -> Void
    private weak var actions: (any DebugWorkflowActions)?

    init(notify: @escaping @MainActor (String) -> Void) {
        self.notify = notify
    }

    /// Held weakly: the application aggregate owns this coordinator.
    func connect(actions: any DebugWorkflowActions) {
        self.actions = actions
    }

    func saveDirtyDocumentIfNeeded(_ document: EditorDocument?) async -> Bool {
        guard let document, (document.isDirty || document.needsEditorSynchronization) else { return true }
        guard let actions else { return false }
        do {
            let previousText = document.savedText
            try await actions.save(document)
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

    /// Resolves the launch configuration of the plugin whose debug adapter
    /// serves the provider's language.
    func prepare(
        provider: LanguageProviderDescriptor,
        fileURL: URL,
        workspaceURL: URL,
        resolver: DebugLaunchConfigurationResolver
    ) throws -> DebugLaunchConfiguration {
        try Task.checkCancellation()
        return try resolver.resolve(
            provider: provider,
            documentURL: fileURL,
            workspaceURL: workspaceURL
        )
    }
}
