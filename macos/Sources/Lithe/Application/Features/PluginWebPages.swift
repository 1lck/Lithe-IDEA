import Foundation

/// A loaded plugin page as the platform shows it.
@MainActor
protocol PluginWebPageHandle: AnyObject {
    /// Unloads the page and ends its bridge; a closed handle is not reused.
    func close()
}

/// The plugin web pages of one project window. A page is created the first
/// time its window is shown, kept while the window is hidden, and closed
/// when its plugin is disabled, updated or uninstalled, or the workspace
/// closes. The window shell around it stays the workbench's.
@MainActor
final class PluginWebPages {
    /// By tool-window contribution ID.
    let windows: [String: PluginWebWindow]
    let stateStore: any PluginWebStateStoring
    private let prompt: @MainActor (PluginWebProcessConsent) async -> Bool
    private var pages: [String: any PluginWebPageHandle] = [:]
    private var unavailablePluginIDs: Set<String> = []
    /// Plugin and workspace pairs the user let start build tools in this session.
    private var allowed: Set<String> = []
    private var prompts: [String: Task<Bool, Never>] = [:]

    init(
        windows: [PluginWebWindow] = [],
        stateStore: (any PluginWebStateStoring)? = nil,
        prompt: @escaping @MainActor (PluginWebProcessConsent) async -> Bool = { _ in false }
    ) {
        self.windows = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        self.stateStore = stateStore ?? MemoryPluginWebStateStore()
        self.prompt = prompt
    }

    /// The open page of a window, created by `make` on first use.
    func page<Page: PluginWebPageHandle>(for windowID: String, make: (PluginWebWindow) -> Page) -> Page? {
        guard let window = windows[windowID], !unavailablePluginIDs.contains(window.pluginID) else { return nil }
        if let page = pages[windowID] { return page as? Page }
        let page = make(window)
        pages[windowID] = page
        return page
    }

    var openWindowIDs: Set<String> { Set(pages.keys) }

    /// Closes the pages of these plugins and forgets the build-tool answers
    /// given to them, so a re-enabled or updated plugin asks again.
    func closePages(of pluginIDs: Set<String>) {
        unavailablePluginIDs.formUnion(pluginIDs)
        for (id, page) in pages where windows[id].map({ pluginIDs.contains($0.pluginID) }) == true {
            pages.removeValue(forKey: id)
            page.close()
        }
        allowed = allowed.filter { key in !pluginIDs.contains { key.hasPrefix($0 + "\n") } }
        for (key, task) in prompts where pluginIDs.contains(where: { key.hasPrefix($0 + "\n") }) {
            task.cancel()
            prompts.removeValue(forKey: key)
        }
    }

    /// Called only after live enablement succeeds for the original package.
    func allowPages(of pluginID: String) {
        unavailablePluginIDs.remove(pluginID)
    }

    func closeAll() {
        let open = pages.values
        pages.removeAll()
        open.forEach { $0.close() }
        allowed.removeAll()
        prompts.values.forEach { $0.cancel() }
        prompts.removeAll()
        // Closing a workspace does not undo plugin disablement or a staged
        // package replacement. Only successful live enablement lifts those blocks.
    }

    /// Asks once per plugin and workspace in this session. A request with
    /// arguments the page supplied asks every time and shows them.
    func confirmProcessStart(_ consent: PluginWebProcessConsent) async -> Bool {
        guard !unavailablePluginIDs.contains(consent.pluginID) else { return false }
        let key = consent.pluginID + "\n" + consent.workspaceURL.standardizedFileURL.path
        guard consent.userArguments.isEmpty else { return await prompt(consent) }
        if allowed.contains(key) { return true }
        if let pending = prompts[key] {
            let isAllowed = await pending.value
            return isAllowed && !pending.isCancelled && !unavailablePluginIDs.contains(consent.pluginID)
        }
        let task = Task { @MainActor [prompt] in await prompt(consent) }
        prompts[key] = task
        let isAllowed = await task.value
        if prompts[key] == task {
            prompts.removeValue(forKey: key)
            if isAllowed && !task.isCancelled { allowed.insert(key) }
        }
        return isAllowed && !task.isCancelled
    }
}
