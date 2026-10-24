import Foundation

extension AppModel {
    /// Tells someone who used the former built-in database module, once,
    /// that the Database plugin replaces it, with a way to the Marketplace.
    func suggestDatabasePluginIfNeeded() {
        let store = services.store
        guard DatabasePluginTransition.shouldSuggest(
            store: store,
            installedPluginIDs: Set(services.pluginManager.snapshots.map(\.id))
        ) else { return }
        store.set(true, forKey: DatabasePluginTransition.suggestionKey)
        showNotification(
            "Database is now a plugin. Install it from the Marketplace, and your saved connections and passwords move into it.",
            action: WorkbenchNotification.Action(title: "Open Marketplace") { [weak self] in
                self?.showPluginMarketplace(searching: "Database")
            }
        )
    }
}
