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
    static let detailMinimumWidth: CGFloat = 160
    @EnvironmentObject private var model: AppModel
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

    @EnvironmentObject private var model: AppModel
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
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settingsState: SettingsViewState
    @ObservedObject var feature: PluginMarketplaceFeatureModel
    @State private var searchText = ""
    @State private var selectedPluginID: PluginID?
    @State private var hoveredPluginID: PluginID?
    @State private var isManagingPackage = false
    @State private var confirmingUninstall: PluginManagementSnapshot?
    @AppStorage("lithe.settings.pluginListWidth") private var pluginListWidth = 320.0

    private var pendingEnabledStates: [PluginID: Bool] { settingsState.pendingPluginEnabledStates }
    private var isApplyingChanges: Bool { settingsState.isApplyingPluginChanges }

    private var installedPlugins: [PluginManagementSnapshot] {
        PluginManagementListContent(plugins: model.pluginSnapshots).plugins
    }

    private var filteredPlugins: [PluginManagementSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return installedPlugins }
        return installedPlugins.filter {
            $0.manifest.displayName.lowercased().contains(query) ||
                $0.manifest.vendor.displayName.lowercased().contains(query)
        }
    }

    private var selectedPlugin: PluginManagementSnapshot? {
        filteredPlugins.first { $0.id == selectedPluginID } ?? filteredPlugins.first
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
            GeometryReader { geometry in
                LitheSplitPaneView(
                    axis: .horizontal,
                    placement: .leading,
                    defaultSize: CGFloat(pluginListWidth),
                    minimum: PluginManagementView.listMinimumWidth,
                    maximum: max(
                        PluginManagementView.listMinimumWidth,
                        geometry.size.width - SplitHandleView.thickness - PluginManagementView.detailMinimumWidth
                    ),
                    flexibleMinimum: PluginManagementView.detailMinimumWidth,
                    onCommit: { pluginListWidth = Double($0) },
                    sized: { sidebar },
                    flexible: { detail }
                )
            }
            if !pendingEnabledStates.isEmpty || isApplyingChanges {
                footer
            }
        }
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                LitheSettingsSearchField("Type / to see options", text: $searchText)
            }
            .padding(.horizontal, 8).frame(height: 44)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Text(LocalizedStringKey("Installed (\(enabledPluginCount) of \(installedPlugins.count) enabled)"))
                    .font(LitheTheme.settingsFont)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 38).background(LitheTheme.settingsListSurface)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPlugins) { plugin in
                        pluginRow(plugin)
                    }
                    ForEach(brokenPluginIssues) { issue in
                        brokenPluginRow(issue)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(LitheTheme.settingsListSurface)
    }

    private func pluginRow(_ plugin: PluginManagementSnapshot) -> some View {
        let isSelected = selectedPlugin?.id == plugin.id
        let isHovered = hoveredPluginID == plugin.id
        return HStack(spacing: 10) {
            pluginIcon(plugin, size: 32)
                .scaleEffect(isHovered && !isSelected ? 1.06 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(plugin.manifest.displayName)).lineLimit(1)
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                Text(verbatim: "\(plugin.manifest.version)  \(plugin.manifest.vendor.displayName)")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            if feature.availableUpdate(for: plugin.id) != nil {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(LitheTheme.accent)
                    .help("Update available")
            }
            Image(systemName: effectiveEnabledState(for: plugin) ? "checkmark.square.fill" : "square")
                .foregroundStyle(effectiveEnabledState(for: plugin) ? LitheTheme.accent : LitheTheme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? LitheTheme.settingsSelection
                : (isHovered ? LitheTheme.hoverBackground : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            selectedPluginID = plugin.id
        }
        .onHover { hovering in
            if hovering {
                hoveredPluginID = plugin.id
            } else if hoveredPluginID == plugin.id {
                hoveredPluginID = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selectedPluginID = plugin.id }
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
                    .controlSize(.small)
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
            ScrollView {
                pluginDetail(plugin)
            }
            .litheScrollViewChrome()
            .background(LitheTheme.settingsSurface)
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

    private func pluginDetail(_ plugin: PluginManagementSnapshot) -> some View {
        let isEnabled = effectiveEnabledState(for: plugin)
        let hasPendingChange = pendingEnabledStates[plugin.id] != nil
        let sourceID = feature.installedSourceID(for: plugin.id)
        let source = feature.sources.first { $0.id == sourceID }
        let update = feature.availableUpdate(for: plugin.id)
        let isBusy = isManagingPackage || feature.busyPluginIDs.contains(plugin.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                pluginIcon(plugin, size: 48)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(plugin.manifest.displayName))
                            .font(LitheTheme.uiFont(size: 22, weight: .bold))
                        if plugin.origin == .community {
                            PluginTrustBadge(isOfficial: false)
                        }
                    }
                    Text(verbatim: "\(plugin.manifest.vendor.displayName) · \(plugin.manifest.version)")
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
            }
            .padding(24)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 10) {
                Button(LocalizedStringKey(isEnabled ? "Disable" : "Enable")) {
                    stageEnabledState(!isEnabled, for: plugin)
                }
                .buttonStyle(.borderedProminent)
                .tint(LitheTheme.accent)
                .disabled(isApplyingChanges || isBusy || plugin.isRequired)
                if let update {
                    Button(String(
                        format: PluginMarketplacePresentation.localized("Update to %@", locale: locale),
                        update.entry.availability.download?.version ?? update.entry.latestVersion
                    )) {
                        performPackageAction { await feature.install(update) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isApplyingChanges || isBusy)
                }
                if sourceID != nil {
                    Button(LocalizedStringKey("Reinstall")) {
                        performPackageAction { await feature.reinstall(plugin.id) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isApplyingChanges || isBusy)
                }
                if plugin.installationStatus == .removed {
                    Button(LocalizedStringKey("Restore")) {
                        model.restorePlugin(plugin.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isApplyingChanges || isBusy)
                } else if plugin.origin != .bundled || OfficialPluginCatalog.entry(for: plugin.id) != nil {
                    // Built-in feature groups are listed as bundled too, but
                    // only an official plugin package can be removed.
                    Button(LocalizedStringKey("Uninstall")) {
                        confirmingUninstall = plugin
                    }
                    .buttonStyle(.bordered)
                    .disabled(isApplyingChanges || isBusy || plugin.isRequired)
                }
                if plugin.hasChangesPendingRestart {
                    RestartLitheButton(prominent: false)
                }
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }.padding(24)
            Text(LocalizedStringKey("Overview")).font(LitheTheme.uiFont(size: 15, weight: .semibold)).padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: summary(for: plugin))
                    .foregroundStyle(LitheTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = feature.errors[plugin.id] {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(
                    LocalizedStringKey(hasPendingChange ? "Pending confirmation" : plugin.statusMessage),
                    systemImage: hasPendingChange ? "clock.badge.exclamationmark" : (isEnabled ? "checkmark.circle.fill" : "pause.circle")
                )
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(hasPendingChange ? LitheTheme.warning : (isEnabled ? LitheTheme.success : LitheTheme.secondaryText))
                if let source {
                    Label(
                        String(
                            format: PluginMarketplacePresentation.localized("Installed from %@", locale: locale),
                            PluginMarketplacePresentation.sourceName(source, locale: locale)
                        ),
                        systemImage: "shippingbox"
                    )
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                }
                if let disk = plugin.disk {
                    Label(LocalizedStringKey("Installed from Disk"), systemImage: "externaldrive")
                        .font(LitheTheme.smallFont)
                    Text(verbatim: disk.fileName)
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .textSelection(.enabled)
                }
                if let repository = plugin.marketplace?.repository, let url = URL(string: repository) {
                    Link(destination: url) {
                        Label(LocalizedStringKey("Source Repository"), systemImage: "arrow.up.right.square")
                    }
                    .font(LitheTheme.smallFont)
                }
                if let replacementID = OfficialPluginCatalog.entry(for: plugin.id)?.communityReplacementID {
                    // The old package keeps its language until the next launch
                    // removes it, so the community version is installed after
                    // that restart, not beside the old one.
                    let uninstalling = plugin.installationStatus == .uninstallPending
                    Label(
                        String(
                            format: PluginMarketplacePresentation.localized(
                                uninstalling
                                    ? "Restart Lithe to finish uninstalling %@, then install the community plugin %@ from the Marketplace."
                                    : "%@ is no longer an official plugin. It moved to the community plugin %@ in Lithe Store and gets no further updates here. Uninstall it, restart Lithe, then install the community version from the Marketplace.",
                                locale: locale
                            ),
                            plugin.manifest.displayName,
                            replacementID.rawValue
                        ),
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                }
                if plugin.origin == .community {
                    Label(
                        LocalizedStringKey(plugin.disk == nil
                            ? "Community plugin maintained by a third party. Report plugin problems in its own repository."
                            : "Community plugin installed from disk. Its publisher and repository have not been verified."),
                        systemImage: "person.2"
                    )
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if plugin.origin == .localDevelopment {
                    Label(
                        LocalizedStringKey("Unsigned development package. Release builds of Lithe will not load it."),
                        systemImage: "hammer"
                    )
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.warning)
                }
            }
            .padding(24)
            if !plugin.settings.isEmpty {
                PluginSettingsSection(
                    settings: plugin.settings,
                    onChange: { settingID, value in
                        model.setPluginSetting(value, id: settingID, for: plugin.id)
                    },
                    onRestartLanguageServers: { model.restartLanguageServers() }
                )
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text(LocalizedStringKey("Pending plugin changes: \(pendingEnabledStates.count)"))
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            Button(LocalizedStringKey("Cancel")) {
                settingsState.pendingPluginEnabledStates.removeAll()
            }
            .buttonStyle(.bordered)
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
            .buttonStyle(.borderedProminent)
            .tint(LitheTheme.accent)
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
            PluginMarketplaceIcon(entry: marketplaceEntry(for: plugin.id), size: size)
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
