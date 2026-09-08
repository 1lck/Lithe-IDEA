import SwiftUI
import LitheModuleAPI

struct PluginManagementView: View {
    @EnvironmentObject private var model: AppModel
    @State private var searchText = ""
    @State private var selectedPluginID: PluginID?
    @State private var hoveredPluginID: PluginID?
    @State private var pendingEnabledStates: [PluginID: Bool] = [:]
    @State private var isApplyingChanges = false
    @State private var isLanguageExtensionsExpanded = false

    private var filteredPlugins: [PluginManagementSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.pluginSnapshots }
        return model.pluginSnapshots.filter {
            $0.manifest.displayName.lowercased().contains(query) ||
                $0.manifest.vendor.displayName.lowercased().contains(query)
        }
    }

    private var selectedPlugin: PluginManagementSnapshot? {
        filteredPlugins.first { $0.id == selectedPluginID } ?? filteredPlugins.first
    }

    private var listContent: PluginManagementListContent {
        PluginManagementListContent(plugins: filteredPlugins)
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsLanguageExtensions: Bool {
        isLanguageExtensionsExpanded || isSearching
    }

    private var enabledPluginCount: Int {
        model.pluginSnapshots.filter { effectiveEnabledState(for: $0) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                detail
            }
            footer
        }
        .frame(minWidth: 820, minHeight: 560)
        .litheWorkbenchSurface(LitheTheme.window)
        .onAppear {
            let initialContent = PluginManagementListContent(plugins: model.pluginSnapshots)
            selectedPluginID = initialContent.standalonePlugins.first?.id
                ?? initialContent.languageExtensions.first?.id
        }
        .onChange(of: searchText) { newValue in
            if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isLanguageExtensionsExpanded = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            Text(LocalizedStringKey("Plugins")).font(.system(size: 17, weight: .semibold))
            Spacer()
            Text(LocalizedStringKey("Marketplace")).foregroundStyle(LitheTheme.secondaryText)
            HStack(spacing: 7) {
                Text(LocalizedStringKey("Installed"))
                Text("\(model.pluginSnapshots.count)")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(LitheTheme.selection)
                    .clipShape(Circle())
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(LitheTheme.selection.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            Image(systemName: "gearshape").foregroundStyle(LitheTheme.secondaryText)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(LitheTheme.secondaryText)
                TextField(LocalizedStringKey("Type / to see options"), text: $searchText)
                    .textFieldStyle(.plain)
                Image(systemName: "ellipsis").foregroundStyle(LitheTheme.secondaryText)
            }
            .padding(.horizontal, 14).frame(height: 48)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Text(LocalizedStringKey("Downloaded (\(model.pluginSnapshots.count) of \(enabledPluginCount) enabled)"))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button(LocalizedStringKey("Install")) { model.installPluginPackage() }
                    .buttonStyle(.borderless).foregroundStyle(LitheTheme.accent)
            }
            .padding(.horizontal, 14).frame(height: 38).background(LitheTheme.raised)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(listContent.standalonePlugins) { plugin in
                        pluginRow(plugin)
                    }
                    if !listContent.languageExtensions.isEmpty {
                        languageExtensionsDisclosure
                        if showsLanguageExtensions {
                            ForEach(listContent.languageExtensions) { plugin in
                                pluginRow(plugin, isNested: true)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 320)
        .litheWorkbenchSurface(LitheTheme.sidebar)
    }

    private var languageExtensionsDisclosure: some View {
        let plugins = listContent.languageExtensions
        let enabledCount = plugins.filter { effectiveEnabledState(for: $0) }.count
        return Button {
            toggleLanguageExtensions()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: showsLanguageExtensions ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .frame(width: 14)
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LitheTheme.accent)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("More Language Support"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(LocalizedStringKey("\(plugins.count) languages · \(enabledCount) enabled"))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
                Spacer()
                Text("\(plugins.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LitheTheme.raised)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsLanguageExtensions ? Text("Expanded") : Text("Collapsed"))
        .lithePointer()
    }

    private func toggleLanguageExtensions() {
        guard !isSearching else { return }
        if isLanguageExtensionsExpanded,
           let selectedPluginID,
           listContent.languageExtensions.contains(where: { $0.id == selectedPluginID }) {
            self.selectedPluginID = listContent.standalonePlugins.first?.id
        }
        isLanguageExtensionsExpanded.toggle()
    }

    private func pluginRow(_ plugin: PluginManagementSnapshot, isNested: Bool = false) -> some View {
        let presentation = presentation(for: plugin)
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
        .padding(.leading, isNested ? 32 : 14)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? LitheTheme.selection
                : (isHovered ? LitheTheme.raised : Color.clear)
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
        .lithePointer()
    }

    @ViewBuilder private var detail: some View {
        if let plugin = selectedPlugin {
            let presentation = presentation(for: plugin)
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
                    if plugin.origin == .marketplace {
                        Button(LocalizedStringKey("Uninstall"), role: .destructive) { model.uninstallPlugin(plugin.id) }
                            .buttonStyle(.bordered)
                            .disabled(isApplyingChanges)
                    }
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
            if !pendingEnabledStates.isEmpty || isApplyingChanges {
                Text(LocalizedStringKey("Pending plugin changes: \(pendingEnabledStates.count)"))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                Button(LocalizedStringKey("Cancel")) {
                    pendingEnabledStates.removeAll()
                }
                .buttonStyle(.bordered)
                .disabled(isApplyingChanges)
                Button {
                    applyPendingChanges()
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
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .litheWorkbenchSurface(LitheTheme.toolHeader)
        .animation(.easeOut(duration: 0.15), value: pendingEnabledStates.isEmpty)
    }

    private func effectiveEnabledState(for plugin: PluginManagementSnapshot) -> Bool {
        pendingEnabledStates[plugin.id] ?? plugin.isEnabled
    }

    private func stageEnabledState(_ enabled: Bool, for plugin: PluginManagementSnapshot) {
        if enabled == plugin.isEnabled {
            pendingEnabledStates.removeValue(forKey: plugin.id)
        } else {
            pendingEnabledStates[plugin.id] = enabled
        }
    }

    private func applyPendingChanges() {
        let changes = pendingEnabledStates
        guard !changes.isEmpty, !isApplyingChanges else { return }
        isApplyingChanges = true
        Task { @MainActor in
            let appliedPluginIDs = await model.applyPluginEnabledChanges(changes)
            for pluginID in appliedPluginIDs {
                pendingEnabledStates.removeValue(forKey: pluginID)
            }
            isApplyingChanges = false
        }
    }

    private func presentation(for plugin: PluginManagementSnapshot) -> PluginPresentation {
        let id = plugin.id.rawValue
        if id == "dev.lithe.plugin.database" {
            return PluginPresentation(
                systemImage: "cylinder.split.1x2",
                tint: LitheTheme.warning,
                summary: "Connect to databases, browse schemas, edit data, run SQL, and manage backups from the Database workspace."
            )
        }
        if id == "dev.lithe.plugin.go-support" {
            return PluginPresentation(
                systemImage: "g.circle.fill",
                tint: LitheTheme.accent,
                summary: "Adds Go language-server integration, formatting, running, and test support."
            )
        }

        let languageID = plugin.manifest.languageSupports?.first?.id ?? ""
        let supportsExecution = plugin.manifest.modules.contains {
            $0.manifest.providedCapabilities.contains(.languageExecutionExtension(languageID))
        }
        let summary = supportsExecution
            ? "Adds language-server integration, formatting, running, and test support."
            : "Adds language-server integration and formatting support."

        switch languageID {
        case "python": return .init(systemImage: "chevron.left.forwardslash.chevron.right", tint: LitheTheme.warning, summary: summary)
        case "node": return .init(systemImage: "hexagon.fill", tint: LitheTheme.success, summary: summary)
        case "rust": return .init(systemImage: "gearshape.2.fill", tint: Color.orange, summary: summary)
        case "swift": return .init(systemImage: "swift", tint: Color.orange, summary: summary)
        case "clangd", "csharp", "fsharp", "kotlin", "scala", "groovy", "zig", "solidity":
            return .init(systemImage: "chevron.left.forwardslash.chevron.right", tint: LitheTheme.accent, summary: summary)
        case "html", "css", "vue", "svelte", "astro", "php":
            return .init(systemImage: "globe", tint: LitheTheme.success, summary: summary)
        case "json", "yaml", "xml", "toml", "graphql", "protobuf", "prisma":
            return .init(systemImage: "curlybraces.square.fill", tint: Color.cyan, summary: summary)
        case "markdown": return .init(systemImage: "doc.richtext.fill", tint: LitheTheme.secondaryText, summary: summary)
        case "sql": return .init(systemImage: "cylinder.fill", tint: LitheTheme.warning, summary: summary)
        case "dockerfile": return .init(systemImage: "shippingbox.fill", tint: Color.cyan, summary: summary)
        case "terraform": return .init(systemImage: "square.3.layers.3d", tint: Color.indigo, summary: summary)
        case "shell", "powershell", "make", "cmake":
            return .init(systemImage: "terminal.fill", tint: LitheTheme.secondaryText, summary: summary)
        default: return .init(systemImage: "puzzlepiece.extension.fill", tint: LitheTheme.accent, summary: summary)
        }
    }
}

struct PluginManagementListContent {
    let standalonePlugins: [PluginManagementSnapshot]
    let languageExtensions: [PluginManagementSnapshot]

    init(plugins: [PluginManagementSnapshot]) {
        standalonePlugins = plugins.filter { plugin in
            plugin.manifest.languageSupports?.isEmpty != false
        }
        languageExtensions = plugins.filter { plugin in
            plugin.manifest.languageSupports?.isEmpty == false
        }
    }
}

private struct PluginPresentation {
    let systemImage: String
    let tint: Color
    let summary: String
}
