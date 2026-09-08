import Combine

/// Owns compatibility change relays while views migrate to scoped feature models.
/// Business-specific subscriptions stay with their owning feature or coordinator.
@MainActor
final class AppModelObservationBinder {
    private var observations: [AnyCancellable]

    init(graph: AppModelFeatureGraph, onChange: @escaping @MainActor () -> Void) {
        let publishers: [ObservableObjectPublisher] = [
            graph.workbenchBackground.objectWillChange,
            graph.workspace.objectWillChange,
            graph.github.objectWillChange,
            graph.runtime.objectWillChange,
            graph.navigationHistory.objectWillChange,
            graph.editorTabOrder.objectWillChange,
            graph.terminalPlacement.objectWillChange,
            graph.document.objectWillChange,
            graph.media.objectWillChange,
            graph.java.objectWillChange,
            graph.notification.objectWillChange,
            graph.workbench.objectWillChange,
            graph.commitDraft.objectWillChange,
            graph.searchSession.objectWillChange,
            graph.workspaceSession.objectWillChange,
            graph.languageNavigation.objectWillChange
        ]
        observations = publishers.map { publisher in
            publisher.sink { onChange() }
        }
    }
}
