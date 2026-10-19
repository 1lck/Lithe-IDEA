import Foundation

// Note: 插件网页生命周期跨项目窗口的边界见 .agents/notes/implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md

/// Package and enablement changes apply to every project window in this
/// process, including pages detached while their tool window is hidden.
@MainActor
final class PluginWebPageLifecycle {
    static let shared = PluginWebPageLifecycle()

    private struct Registration {
        weak var pages: PluginWebPages?
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]
    private var disabledPluginIDs: Set<String> = []
    /// Old project containers still refer to the package loaded at launch.
    /// Enabling from one of those containers must never reopen replaced bytes.
    private var replacedPluginIDs: Set<String> = []

    func register(_ pages: PluginWebPages) {
        pruneRegistrations()
        registrations[ObjectIdentifier(pages)] = Registration(pages: pages)
        pages.closePages(of: disabledPluginIDs.union(replacedPluginIDs))
    }

    func disable(_ pluginID: String) {
        disabledPluginIDs.insert(pluginID)
        forEachPages { $0.closePages(of: [pluginID]) }
    }

    /// Called after candidate validation and before the installed package or
    /// installation record changes. No live enablement can lift this block.
    func packageWillChange(_ pluginID: String) {
        replacedPluginIDs.insert(pluginID)
        forEachPages { $0.closePages(of: [pluginID]) }
    }

    func enable(_ pluginID: String) {
        guard !replacedPluginIDs.contains(pluginID) else { return }
        disabledPluginIDs.remove(pluginID)
        forEachPages { $0.allowPages(of: pluginID) }
    }

    private func forEachPages(_ body: (PluginWebPages) -> Void) {
        pruneRegistrations()
        for registration in registrations.values {
            if let pages = registration.pages { body(pages) }
        }
    }

    private func pruneRegistrations() {
        registrations = registrations.filter { $0.value.pages != nil }
    }
}
