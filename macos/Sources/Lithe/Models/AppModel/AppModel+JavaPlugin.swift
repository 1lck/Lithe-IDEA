import Foundation
import LitheModuleAPI

extension AppModel {
    /// One notice per window session keeps offline failures retryable on the
    /// next launch, without repeating it for each file in a Java project.
    func suggestJavaPluginIfNeeded(files: [URL]) {
        guard !hasSuggestedJavaPlugin,
              JavaPluginTransition.shouldSuggest(
                files: files,
                plugins: services.pluginManager.snapshots
              ) else { return }
        hasSuggestedJavaPlugin = true
        showNotification(
            L10n.string("Java Support is installed separately. Install it from the Marketplace, or use Install from Disk for an offline package. Your Java settings are kept."),
            action: WorkbenchNotification.Action(title: L10n.string("Open Marketplace")) { [weak self] in
                self?.showPluginMarketplace(searching: "Java Support")
            }
        )
    }
}
