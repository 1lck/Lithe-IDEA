import SwiftUI
import LitheModuleAPI

struct PluginManagementView: View {
    static let minimumWidth: CGFloat = listMinimumWidth + SplitHandleView.thickness + detailMinimumWidth
    static let listMinimumWidth: CGFloat = 200
    private static let detailMinimumWidth: CGFloat = 160
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settingsState: SettingsViewState
    @State private var searchText = ""
    @State private var selectedPluginID: PluginID?
    @State private var hoveredPluginID: PluginID?
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

    private var availablePHPManifest: PluginManifest? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let manifest = PluginManagementListContent(plugins: model.pluginSnapshots).availablePHPManifest,
              query.isEmpty || manifest.displayName.lowercased().contains(query) else { return nil }
        return manifest
    }

    private var enabledPluginCount: Int {
        installedPlugins.filter { effectiveEnabledState(for: $0) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                LitheSplitPaneView(
                    axis: .horizontal,
                    placement: .leading,
                    defaultSize: CGFloat(pluginListWidth),
                    minimum: Self.listMinimumWidth,
                    maximum: max(Self.listMinimumWidth, geometry.size.width - SplitHandleView.thickness - Self.detailMinimumWidth),
                    flexibleMinimum: Self.detailMinimumWidth,
                    highlightsOnHover: false,
                    onCommit: { pluginListWidth = Double($0) },
                    sized: { sidebar },
                    flexible: { detail }
                )
            }
            if !pendingEnabledStates.isEmpty || isApplyingChanges {
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LitheTheme.settingsSurface)
        .onAppear {
            selectedPluginID = installedPlugins.first?.id
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            Text(LocalizedStringKey("Plugins")).font(LitheTheme.settingsStrongFont)
            Spacer()
            Text(LocalizedStringKey("Marketplace"))
                .foregroundStyle(LitheTheme.secondaryText)
                .help("Plugin marketplace is not available")
            Text(LocalizedStringKey("Installed"))
                .font(LitheTheme.settingsFont)
                .padding(.horizontal, 12).padding(.vertical, 7)
            .background(LitheTheme.settingsSelection)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(LitheTheme.settingsSurface)
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
                    if let manifest = availablePHPManifest {
                        availablePluginRow(manifest)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(LitheTheme.settingsListSurface)
    }

    private func pluginRow(_ plugin: PluginManagementSnapshot) -> some View {
        let presentation = phpPresentation
        let isSelected = selectedPlugin?.id == plugin.id
        let isHovered = hoveredPluginID == plugin.id
        return HStack(spacing: 10) {
            Image(systemName: presentation.systemImage)
                .font(.system(size: 22)).foregroundStyle(presentation.tint)
                .frame(width: 42, height: 42)
                .scaleEffect(isHovered && !isSelected ? 1.06 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(plugin.manifest.displayName)).lineLimit(1)
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: "\(plugin.manifest.version)  \(plugin.manifest.vendor.displayName)")
                    .font(LitheTheme.smallFont).foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
            Image(systemName: effectiveEnabledState(for: plugin) ? "checkmark.square.fill" : "square")
                .foregroundStyle(effectiveEnabledState(for: plugin) ? LitheTheme.accent : LitheTheme.secondaryText)
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
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
    }

    private func availablePluginRow(_ manifest: PluginManifest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: phpPresentation.systemImage)
                .font(.system(size: 22))
                .foregroundStyle(phpPresentation.tint)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(manifest.displayName))
                    .font(.system(size: 13, weight: .semibold))
                Text(LocalizedStringKey("Not installed"))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.settingsSelection)
    }

    @ViewBuilder private var detail: some View {
        if let plugin = selectedPlugin {
            let presentation = phpPresentation
            let isEnabled = effectiveEnabledState(for: plugin)
            let hasPendingChange = pendingEnabledStates[plugin.id] != nil
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: presentation.systemImage)
                        .font(.system(size: 38)).foregroundStyle(presentation.tint)
                        .frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(LocalizedStringKey(plugin.manifest.displayName)).font(.system(size: 22, weight: .bold))
                        Text("Lithe · \(plugin.manifest.vendor.displayName)").foregroundStyle(LitheTheme.secondaryText)
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
                    .disabled(isApplyingChanges || plugin.isRequired)
                }.padding(24)
                Text(LocalizedStringKey("Overview")).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 24)
                VStack(alignment: .leading, spacing: 12) {
                    Text(LocalizedStringKey(presentation.summary))
                        .foregroundStyle(LitheTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(
                        LocalizedStringKey(hasPendingChange ? "Pending confirmation" : plugin.statusMessage),
                        systemImage: hasPendingChange ? "clock.badge.exclamationmark" : (isEnabled ? "checkmark.circle.fill" : "pause.circle")
                    )
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(hasPendingChange ? LitheTheme.warning : (isEnabled ? LitheTheme.success : LitheTheme.secondaryText))
                }
                .padding(24)
                Spacer()
            }
            .background(LitheTheme.settingsSurface)
        } else if let manifest = availablePHPManifest {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringKey(manifest.displayName))
                    .font(.system(size: 22, weight: .bold))
                Text(LocalizedStringKey("Install PHP Support from a signed plugin package."))
                    .foregroundStyle(LitheTheme.secondaryText)
                Button(LocalizedStringKey("Install Plugin from Disk…")) {
                    model.installPHPPluginPackage()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplyingChanges)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 30))
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(LocalizedStringKey("No Plugins"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var phpPresentation: PluginPresentation {
        PluginPresentation(
            systemImage: "globe",
            tint: LitheTheme.success,
            summary: "Adds PHP language-server integration, formatting, running, and test support."
        )
    }
}

struct PluginManagementListContent {
    let plugins: [PluginManagementSnapshot]

    var availablePHPManifest: PluginManifest? {
        guard plugins.isEmpty else { return nil }
        return OfficialPluginCatalog.manifests.first { $0.id == OfficialPluginCatalog.phpPluginID }
    }

    init(plugins: [PluginManagementSnapshot]) {
        self.plugins = plugins.filter { $0.id == OfficialPluginCatalog.phpPluginID }
    }
}

private struct PluginPresentation {
    let systemImage: String
    let tint: Color
    let summary: String
}
