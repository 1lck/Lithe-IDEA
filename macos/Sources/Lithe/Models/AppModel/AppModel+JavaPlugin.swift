import Foundation
import LitheModuleAPI

extension AppModel {
    /// One notice per window session keeps offline failures retryable on the
    /// next launch, without repeating it for each file in a Java project.
    func suggestJavaPluginIfNeeded(files: [URL]) {
        guard !hasSuggestedJavaPlugin,
              JavaPluginTransition.shouldSuggest(
                files: files,
                installedPluginIDs: Set(services.pluginManager.snapshots.map(\.id))
              ) else { return }
        hasSuggestedJavaPlugin = true
        showNotification(
            String(localized: "Java Support is installed separately. Install it from the Marketplace, or use Install from Disk for an offline package. Your Java settings are kept."),
            action: WorkbenchNotification.Action(title: String(localized: "Open Marketplace")) { [weak self] in
                self?.showPluginMarketplace(searching: "Java Support")
            }
        )
    }
}
