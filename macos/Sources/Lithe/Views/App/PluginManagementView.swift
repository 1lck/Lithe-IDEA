import LitheCoreContracts
import SwiftUI
import LitheModuleAPI

/// Settings › Plugins, laid out like IntelliJ IDEA's plugin manager:
/// Marketplace and Installed tabs, a gear menu for plugin repositories and
/// disk installs, and a list beside the selected plugin's details.
struct PluginManagementView: View {
    enum Tab: String {
        case marketplace
        case installed
    }

    static let minimumWidth: CGFloat = listMinimumWidth + SplitHandleView.thickness + detailMinimumWidth
    static let listMinimumWidth: CGFloat = 200
    /// The split layout already reserves `detailMinimumWidth`, so the list
    /// bound is a constant rather than read from live window geometry.
    static let listMaximumWidth: CGFloat = 520
    static let detailMinimumWidth: CGFloat = 160
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @ObservedObject var settingsState: SettingsViewState

    var body: some View {
        PluginManagementPage(settingsState: settingsState, feature: model.pluginMarketplaceFeature)
    }
}

/// Observes the marketplace feature itself: `AppModel` does not republish its
/// changes, so a page that only read it through the model would keep showing
/// a confirmation sheet the feature had already cancelled.
private struct PluginManagementPage: View {
    typealias Tab = PluginManagementView.Tab

    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @ObservedObject var settingsState: SettingsViewState
    @ObservedObject var feature: PluginMarketplaceFeatureModel
    @AppStorage("lithe.settings.pluginTab") private var tab = Tab.installed
    @State private var showsRepositories = false
    @State private var diskInstallTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if feature.hasChangesPendingRestart {
                restartBanner
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            if let error = feature.diskInstallError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .textSelection(.enabled)
                    .padding(12)
            }
            switch tab {
            case .marketplace:
                PluginMarketplaceView(feature: feature)
            case .installed:
                InstalledPluginsView(settingsState: settingsState, feature: feature)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if settingsState.requestedPluginID != nil { tab = .installed } }
        .onChange(of: settingsState.requestedPluginID) { if $0 != nil { tab = .installed } }
        .background(LitheTheme.settingsSurface)
        .onAppear { feature.loadIfNeeded() }
        .onDisappear {
            diskInstallTask?.cancel()
            diskInstallTask = nil
            feature.endInstallationSession()
        }
        // Sheets do not inherit the app's interface language on macOS.
        .sheet(isPresented: $showsRepositories) {
            PluginRepositoriesSheet(feature: feature) { showsRepositories = false }
                .environment(\.locale, model.settings.language.locale)
        }
        .sheet(item: Binding(
            get: { feature.pendingConfirmation },
            set: { if $0 == nil { feature.cancelPendingInstallation() } }
        )) { confirmation in
            PluginInstallConfirmationSheet(
                confirmation: confirmation,
                confirm: {
                    feature.confirmPendingInstallation(id: confirmation.id)
                    model.objectWillChange.send()
                },
                cancel: { feature.cancelPendingInstallation() }
            )
            .environment(\.locale, model.settings.language.locale)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey("Plugins")).font(LitheTheme.settingsStrongFont)
            Spacer()
            tabButton(.marketplace, title: "Marketplace")
            tabButton(.installed, title: "Installed")
            Spacer()
            LitheMenu {
                LitheContextMenuItem.action("Manage Plugin Repositories…") { showsRepositories = true }
                LitheContextMenuItem.action("Refresh Plugin Repositories") {
                    Task { await feature.refreshAll() }
                }
                LitheContextMenuItem.separator
                LitheContextMenuItem.action("Install Plugin from Disk…", isEnabled: !feature.isPreparingDiskInstall) {
                    diskInstallTask = Task { await model.installPluginPackageFromDisk() }
                }
            } label: {
                LitheIDEAIcon(resourcePath: "expui/general/settings.svg", size: 16, fallbackSystemImage: "gearshape")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .help("Plugin settings")
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(LitheTheme.settingsSurface)
    }

    /// Like IntelliJ IDEA's "Restart IDE": plugin installs, updates, and
    /// uninstalls apply at the next launch, so offer it right here.
    private var restartBanner: some View {
        HStack(spacing: 10) {
            Label(LocalizedStringKey("Plugin changes take effect after Lithe restarts."), systemImage: "arrow.clockwise.circle")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            RestartLitheButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func tabButton(_ value: Tab, title: String) -> some View {
        Button {
            tab = value
        } label: {
            Text(LocalizedStringKey(title))
                .font(LitheTheme.settingsFont)
                .foregroundStyle(tab == value ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tab == value ? LitheTheme.settingsSelection : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}

/// Installed tab: enable, disable, update, reinstall, and uninstall.
private struct InstalledPluginsView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @ObservedObject var settingsState: SettingsViewState
    @ObservedObject var feature: PluginMarketplaceFeatureModel
    @State private var searchText = ""
    @State private var selectedPluginID: PluginID?
    @State private var isManagingPackage = false
    @State private var confirmingUninstall: PluginManagementSnapshot?
    @State private var confirmingRollback: PluginManagementSnapshot?
    @State private var filter = PluginListFilter.all
    @State private var detailTab = PluginDetailTab.overview
    @AppStorage("lithe.settings.pluginListWidth") private var pluginListWidth = 320.0

    private var pendingEnabledStates: [PluginID: Bool] { settingsState.pendingPluginEnabledStates }
    private var isApplyingChanges: Bool { settingsState.isApplyingPluginChanges }

    private var installedPlugins: [PluginManagementSnapshot] {
        PluginManagementListContent(plugins: model.pluginSnapshots).plugins
    }

    /// Typing `/` lists the filters instead of searching.
    private var isChoosingFilter: Bool {
        searchText.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    private var filteredPlugins: [PluginManagementSnapshot] {
        let query = isChoosingFilter ? "" : searchText
        return installedPlugins.filter { plugin in
            filter.matches(
                plugin,
                isEnabled: effectiveEnabledState(for: plugin),
                hasUpdate: feature.availableUpdate(for: plugin.id) != nil
            ) && PluginListFilter.matches(plugin, query: query)
        }
    }

    private var selectedPlugin: PluginManagementSnapshot? {
        filteredPlugins.first { $0.id == selectedPluginID } ?? filteredPlugins.first
    }

    /// Opens the plugin another settings page pointed at, on its Settings tab.
    private func showRequestedPlugin() {
        guard let pluginID = settingsState.requestedPluginID else { return }
        settingsState.requestedPluginID = nil
        searchText = ""
        filter = .all
        selectedPluginID = pluginID
        detailTab = .settings
    }

    private var enabledPluginCount: Int {
        installedPlugins.filter { effectiveEnabledState(for: $0) }.count
    }

    /// Plugins whose installed package could not be accepted, for example a
    /// retired native package or a changed community package.
    private var brokenPluginIssues: [PluginManagementIssue] {
        model.pluginManagementIssues.filter { issue in
            guard let pluginID = issue.pluginID else { return false }
            return !installedPlugins.contains { $0.id == pluginID }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: CGFloat(pluginListWidth),
                minimum: PluginManagementView.listMinimumWidth,
                maximum: PluginManagementView.listMaximumWidth,
                flexibleMinimum: PluginManagementView.detailMinimumWidth,
                onCommit: { pluginListWidth = Double($0) },
                sized: { sidebar },
                flexible: { detail }
            )
            if !pendingEnabledStates.isEmpty || isApplyingChanges {
                footer
            }
        }
        .onAppear(perform: showRequestedPlugin)
        .onChange(of: settingsState.requestedPluginID) { _ in showRequestedPlugin() }
        .confirmationDialog(
            Text(String(
                format: PluginMarketplacePresentation.localized("Uninstall %@?", locale: locale),
                confirmingUninstall?.manifest.displayName ?? ""
            )),
            isPresented: Binding(
                get: { confirmingUninstall != nil },
                set: { if !$0 { confirmingUninstall = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("Uninstall"), role: .destructive) {
                if let plugin = confirmingUninstall {
                    performPackageAction { await model.uninstallPlugin(plugin.id) }
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("The plugin will be removed after restarting Lithe."))
        }
        .confirmationDialog(
            Text(String(
                format: PluginMarketplacePresentation.localized("Roll back %@ to %@?", locale: locale),
                confirmingRollback?.manifest.displayName ?? "",
                confirmingRollback?.previousVersion?.description ?? ""
            )),
            isPresented: Binding(
                get: { confirmingRollback != nil },
                set: { if !$0 { confirmingRollback = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(LocalizedStringKey("Roll Back")) {
                if let plugin = confirmingRollback {
                    performPackageAction { model.rollbackPlugin(plugin.id) }
                }
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {}
        } message: {
            Text(LocalizedStringKey("The previous version is used after restarting Lithe. Your setting values are kept."))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                LitheSearchField("Type / to see options", text: $searchText)
                filterChips
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                if isChoosingFilter {
                    filterMenu
                        .padding(.horizontal, 8)
                        .offset(y: 40)
                }
            }
            .zIndex(1)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Text(LocalizedStringKey("Installed (\(enabledPluginCount) of \(installedPlugins.count) enabled)"))
                    .font(LitheTheme.settingsFont)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 38).background(LitheTheme.settingsListSurface)
            // Filter and sort once per render; rows only receive their own state.
            let plugins = filteredPlugins
            let selectedID = (plugins.first { $0.id == selectedPluginID } ?? plugins.first)?.id
            let enabled = plugins.filter { effectiveEnabledState(for: $0) }
            let disabled = plugins.filter { !effectiveEnabledState(for: $0) }
            LitheTreeList(nodes:
                pluginNodes(enabled, title: "Enabled") + pluginNodes(disabled, title: "Disabled")
                    + (filter == .all ? brokenPluginIssues.map { issue in
                        LitheTreeListNode(id: "issue:" + String(describing: issue.id), isSelectable: false) {
                            brokenPluginRow(issue)
                        }
                    } : []),
                selection: Binding(get: { selectedID.map { "plugin:" + $0.rawValue } }, set: { _ in }), multiline: true)

        }
        .frame(maxWidth: .infinity)
        .background(LitheTheme.settingsListSurface)
    }

    private var filterChips: some View {
        // Wraps instead of scrolling so every filter stays visible in a
        // narrow list.
        LitheChipFlowLayout(spacing: 5) {
            ForEach(PluginListFilter.allCases, id: \.self) { value in
                let isSelected = filter == value
                Button {
                    filter = value
                } label: {
                    Text(LocalizedStringKey(value.title))
                        .font(LitheTheme.uiFont(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? LitheTheme.settingsSelectionText : LitheTheme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(isSelected ? LitheTheme.settingsSelection : Color.clear))
                        .overlay(Capsule().stroke(isSelected ? Color.clear : LitheTheme.settingsControlBorder, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.litheNoPress)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    /// Shown while the search text starts with `/`; picking an option sets
    /// the filter and clears the text.
    private var filterMenu: some View {
        let typed = searchText.trimmingCharacters(in: .whitespaces).dropFirst().lowercased()
        let options = PluginListFilter.allCases.filter { $0 != .all && (typed.isEmpty || $0.token.hasPrefix(typed)) }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(options, id: \.self) { value in
                Button {
                    filter = value
                    searchText = ""
                } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: "/\(value.token)")
                            .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                            .frame(width: 92, alignment: .leading)
                        Text(LocalizedStringKey(value.title))
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.litheNoPress)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(LitheTheme.settingsPopupBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(LitheTheme.settingsPopupBorder, lineWidth: 1))
        .shadow(color: LitheTheme.popupShadow, radius: 8, y: 3)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(LitheTheme.uiFont(size: 11, weight: .medium))
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func pluginNodes(_ plugins: [PluginManagementSnapshot], title: String) -> [LitheTreeListNode] {
        guard !plugins.isEmpty else { return [] }
        return [LitheTreeListNode(id: "group:" + (plugins.first?.id.rawValue ?? ""), isSelectable: false) {
            groupHeader(title)
        }] + plugins.map { plugin in
            LitheTreeListNode(id: "plugin:" + plugin.id.rawValue, onSelect: { selectedPluginID = plugin.id }) {
                pluginRow(plugin)
            }
        }
    }

    private func pluginRow(_ plugin: PluginManagementSnapshot) -> some View {
        InstalledPluginRow(
            displayName: plugin.manifest.displayName,
            subtitle: rowSubtitle(plugin),
            hasUpdate: feature.availableUpdate(for: plugin.id) != nil,
            isEnabled: effectiveEnabledState(for: plugin)
        ) {
            pluginIcon(plugin, size: 32)
        }
    }

    /// A plugin whose package was refused. It can only be uninstalled or
    /// replaced from the Marketplace tab.
    private func brokenPluginRow(_ issue: PluginManagementIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LitheTheme.warning)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: issue.pluginID?.rawValue ?? "")
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: issue.message)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let pluginID = issue.pluginID {
                    Button(LocalizedStringKey("Uninstall")) {
                        performPackageAction { await model.uninstallPlugin(pluginID) }
                    }
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(isManagingPackage)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var detail: some View {
        if let plugin = selectedPlugin {
            let sourceID = feature.installedSourceID(for: plugin.id)
            let update = feature.availableUpdate(for: plugin.id)
            PluginDetailView(
                plugin: plugin,
                summary: summary(for: plugin),
                isEnabled: effectiveEnabledState(for: plugin),
                hasPendingChange: pendingEnabledStates[plugin.id] != nil,
                isBusy: isManagingPackage || feature.busyPluginIDs.contains(plugin.id),
                isApplyingChanges: isApplyingChanges,
                updateVersion: update.map { $0.entry.availability.download?.version ?? $0.entry.latestVersion },
                sourceName: feature.sources.first { $0.id == sourceID }
                    .map { PluginMarketplacePresentation.sourceName($0, locale: locale) },
                error: feature.errors[plugin.id],
                actions: actions(for: plugin, sourceID: sourceID, update: update),
                tab: $detailTab
            ) {
                pluginIcon(plugin, size: 48)
            }
            .id(plugin.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(LitheTheme.uiFont(size: 30))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(LocalizedStringKey("No Plugins"))
                    .font(LitheTheme.uiFont(size: 15, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func actions(
        for plugin: PluginManagementSnapshot,
        sourceID: String?,
        update: PluginMarketplaceOffer?
    ) -> PluginDetailActions {
        let isEnabled = effectiveEnabledState(for: plugin)
        // Built-in feature groups are listed as bundled too, but only an
        // official plugin package can be removed.
        let canUninstall = plugin.origin != .bundled || OfficialPluginCatalog.entry(for: plugin.id) != nil
        return PluginDetailActions(
            toggleEnabled: { stageEnabledState(!isEnabled, for: plugin) },
            update: update.map { update in { performPackageAction { await feature.install(update) } } },
            reinstall: sourceID == nil ? nil : { performPackageAction { await feature.reinstall(plugin.id) } },
            uninstall: canUninstall ? { confirmingUninstall = plugin } : nil,
            restore: plugin.installationStatus == .removed ? { model.restorePlugin(plugin.id) } : nil,
            rollback: plugin.canRollback && plugin.installationStatus == .installed
                ? { confirmingRollback = plugin }
                : nil,
            settings: model.pluginSettingsHandlers(for: plugin.id),
            hasProject: model.workspaceURL != nil,
            openSettings: { settingsState.selection = $0 }
        )
    }

    /// Version, vendor, and the main things the plugin provides.
    private func rowSubtitle(_ plugin: PluginManagementSnapshot) -> String {
        let highlighted: Set<PluginCapability.Kind> = [.languageServer, .buildSystem, .toolWindow]
        var seen = Set<String>()
        let provided = plugin.capabilities
            .filter { highlighted.contains($0.kind) && seen.insert($0.title).inserted }
            .map(\.title)
        return ([ "\(plugin.manifest.version)  \(plugin.manifest.vendor.displayName)" ] + provided)
            .joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: LitheTheme.ActionButton.spacing) {
            Spacer()
            Text(LocalizedStringKey("Pending plugin changes: \(pendingEnabledStates.count)"))
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            Button(LocalizedStringKey("Cancel")) {
                settingsState.pendingPluginEnabledStates.removeAll()
            }
            .buttonStyle(LitheActionButtonStyle())
            .disabled(isApplyingChanges)
            Button {
                Task { @MainActor in
                    _ = await settingsState.applyPluginChanges(model.applyPluginEnabledChanges)
                }
            } label: {
                if isApplyingChanges {
                    ProgressView().controlSize(.small)
                } else {
                    Text(LocalizedStringKey("Confirm"))
                }
            }
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .disabled(isApplyingChanges)
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(LitheTheme.settingsSurface)
        .animation(.easeOut(duration: 0.15), value: pendingEnabledStates.isEmpty)
    }

    private func effectiveEnabledState(for plugin: PluginManagementSnapshot) -> Bool {
        pendingEnabledStates[plugin.id] ?? plugin.isEnabled
    }

    private func stageEnabledState(_ enabled: Bool, for plugin: PluginManagementSnapshot) {
        if enabled == plugin.isEnabled {
            settingsState.pendingPluginEnabledStates.removeValue(forKey: plugin.id)
        } else {
            settingsState.pendingPluginEnabledStates[plugin.id] = enabled
        }
    }

    private func performPackageAction(_ action: @escaping @MainActor () async -> Void) {
        guard !isManagingPackage else { return }
        isManagingPackage = true
        Task { @MainActor in
            await action()
            isManagingPackage = false
            model.objectWillChange.send()
        }
    }

    @ViewBuilder
    private func pluginIcon(_ plugin: PluginManagementSnapshot, size: CGFloat) -> some View {
        if let presentation = PluginManagementListContent.officialPresentation(for: plugin.id) {
            Image(systemName: presentation.systemImage)
                .font(LitheTheme.uiFont(size: size * 0.55))
                .foregroundStyle(presentation.tint)
                .frame(width: size, height: size)
        } else {
            PluginMarketplaceIcon(
                icons: feature.icons,
                entry: marketplaceEntry(for: plugin.id),
                size: size,
                fallbackName: plugin.manifest.displayName,
                fallbackKey: plugin.id.rawValue
            )
        }
    }

    private func marketplaceEntry(for pluginID: PluginID) -> PluginMarketplaceEntry? {
        guard let listing = feature.listings.first(where: { $0.pluginID == pluginID }) else { return nil }
        return feature.offer(for: listing)?.entry
    }

    private func summary(for plugin: PluginManagementSnapshot) -> String {
        if let presentation = PluginManagementListContent.officialPresentation(for: plugin.id) {
            return PluginMarketplacePresentation.localized(presentation.summary, locale: locale)
        }
        return marketplaceEntry(for: plugin.id)?.description(for: locale) ?? plugin.manifest.displayName
    }
}

/// Filters of the Installed list; each also has a `/` token in the search
/// field.
enum PluginListFilter: String, CaseIterable {
    case all
    case languageServer
    case buildSystem
    case debug
    case ui
    case update
    case community
    case disabled

    var title: String {
        switch self {
        case .all: "All"
        case .languageServer: "Language Services"
        case .buildSystem: "Build"
        case .debug: "Debug"
        case .ui: "Interface"
        case .update: "Updates"
        case .community: "Community / Disk"
        case .disabled: "Disabled"
        }
    }

    var token: String {
        switch self {
        case .all: "all"
        case .languageServer: "lsp"
        case .buildSystem: "build"
        case .debug: "debug"
        case .ui: "ui"
        case .update: "update"
        case .community: "community"
        case .disabled: "disabled"
        }
    }

    func matches(_ plugin: PluginManagementSnapshot, isEnabled: Bool, hasUpdate: Bool) -> Bool {
        let kinds = Set(plugin.capabilities.map(\.kind))
        return switch self {
        case .all: true
        case .languageServer: kinds.contains(.languageServer)
        case .buildSystem: kinds.contains(.buildSystem)
        case .debug: kinds.contains(.debug)
        case .ui: !kinds.isDisjoint(with: [.toolWindow, .command])
        case .update: hasUpdate
        case .community: plugin.origin == .community || plugin.origin == .localDevelopment || plugin.disk != nil
        case .disabled: !isEnabled
        }
    }

    /// Name, vendor, and capability titles, case-insensitively.
    static func matches(_ plugin: PluginManagementSnapshot, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return ([plugin.manifest.displayName, plugin.manifest.vendor.displayName] + plugin.capabilities.map(\.title))
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct PluginManagementListContent {
    let plugins: [PluginManagementSnapshot]

    /// Built-in language support (Python, Rust, …) is part of Lithe, not a
    /// plugin, so only official plugins and installed packages are listed.
    init(plugins: [PluginManagementSnapshot]) {
        self.plugins = plugins.filter {
            OfficialPluginCatalog.entry(for: $0.id) != nil || $0.origin != .bundled
        }
    }

    struct Presentation {
        let systemImage: String
        let tint: Color
        let summary: String
    }

    /// Host-owned presentation of the official language plugins; other
    /// plugins use their marketplace icon and description.
    static func officialPresentation(for pluginID: PluginID) -> Presentation? {
        switch pluginID {
        case OfficialPluginCatalog.goPluginID:
            Presentation(
                systemImage: "chevron.left.forwardslash.chevron.right",
                tint: LitheTheme.accent,
                summary: "Retired official Go plugin. Go support is now the community plugin Go Support in Lithe Store."
            )
        case OfficialPluginCatalog.javaPluginID:
            Presentation(
                systemImage: "cup.and.saucer",
                tint: LitheTheme.warning,
                summary: "Adds Java language intelligence through the Eclipse JDT language server, with Lombok, debugging, and test support. Ships its own Java runtime."
            )
        case OfficialPluginCatalog.phpPluginID:
            Presentation(
                systemImage: "globe",
                tint: LitheTheme.success,
                summary: "Retired official PHP plugin. PHP support is now the community plugin PHP Support in Lithe Store."
            )
        default:
            nil
        }
    }
}

/// Installed plugin content; the shared tree owns focus, selection, hover and activation.
private struct InstalledPluginRow<Icon: View>: View {
    let displayName: String
    let subtitle: String
    let hasUpdate: Bool
    let isEnabled: Bool
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 10) {
            icon()
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(displayName)).lineLimit(1)
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                Text(verbatim: subtitle)
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            if hasUpdate {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(LitheTheme.accent)
                    .help("Update available")
            }
            Image(systemName: isEnabled ? "checkmark.square.fill" : "square")
                .foregroundStyle(isEnabled ? LitheTheme.accent : LitheTheme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)

    }
}
