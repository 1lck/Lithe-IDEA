import Combine

/// The settings window's handle on a project's `AppModel`.
///
/// Settings pages read and call the same model, but observe only
/// `AppModel.settingsChanges` instead of every relayed workbench change. Like
/// IntelliJ IDEA's settings dialog, editing, indexing, or Git activity in the
/// project window therefore no longer rebuilds the whole settings tree. A page
/// that shows live feature state (for example language server status)
/// observes that feature or `AppModel` itself in its own small view.
@MainActor
final class SettingsModelContext: ObservableObject {
    let model: AppModel

    nonisolated let objectWillChange: ObservableObjectPublisher

    init(model: AppModel) {
        self.model = model
        objectWillChange = model.settingsChanges
    }
}
