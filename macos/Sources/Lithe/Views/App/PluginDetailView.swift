import LitheCoreContracts
import LitheModuleAPI
import SwiftUI

/// Tabs of an installed plugin's details. Trust and migration notices stay in
/// the header so no tab can hide them.
enum PluginDetailTab: String, CaseIterable {
    case overview
    case features
    case settings
    case permissions
    case versions

    var title: String {
        switch self {
        case .overview: "Overview"
        case .features: "Features"
        case .settings: "Settings"
        case .permissions: "Permissions & Programs"
        case .versions: "Versions & Source"
        }
    }
}

/// What the detail's buttons do; the list owns staging and package actions.
struct PluginDetailActions {
    let toggleEnabled: () -> Void
    let update: (() -> Void)?
    let reinstall: (() -> Void)?
    let uninstall: (() -> Void)?
    let restore: (() -> Void)?
    let rollback: (() -> Void)?
    let settings: PluginSettingsHandlers
    /// A project is open, so project-scoped settings can be overridden.
    let hasProject: Bool
    let openSettings: (SettingsCategory) -> Void
}

/// Settings › Plugins › Installed: the selected plugin's header, notices,
/// and tabs.
struct PluginDetailView<Icon: View>: View {
    @Environment(\.locale) private var locale
    let plugin: PluginManagementSnapshot
    let summary: String
    let isEnabled: Bool
    let hasPendingChange: Bool
    let isBusy: Bool
    let isApplyingChanges: Bool
    let updateVersion: String?
    let sourceName: String?
    let error: String?
    let actions: PluginDetailActions
    @Binding var tab: PluginDetailTab
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            notices
            tabBar
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            PluginDetailContent(scrollsHorizontally: tab == .settings, content: tabContent)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(LitheTheme.settingsSurface)
        .clipped()
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                identity
                Spacer(minLength: 12)
                actionButtons
            }
            VStack(alignment: .leading, spacing: 12) {
                identity
                actionButtons
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 14) {
            icon()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(plugin.manifest.displayName))
                        .font(LitheTheme.uiFont(size: 20, weight: .bold))
                        .lineLimit(1)
                    if plugin.origin == .community {
                        PluginTrustBadge(isOfficial: false)
                    } else if plugin.manifest.vendor.signatureRequirement == .publisherPackage,
                              OfficialPluginCatalog.entry(for: plugin.id)?.communityReplacementID == nil {
                        PluginTrustBadge(isOfficial: true)
                    }
                }
                HStack(spacing: 8) {
                    Text(verbatim: "\(plugin.manifest.vendor.displayName) · \(plugin.manifest.version)")
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                    statusPill
                    if plugin.hasChangesPendingRestart {
                        Text(LocalizedStringKey("Takes effect after Lithe restarts"))
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var statusPill: some View {
        let (title, color): (String, Color) = if hasPendingChange {
            ("Pending confirmation", LitheTheme.warning)
        } else if isEnabled {
            (plugin.isRunning ? "Running" : "Enabled", LitheTheme.success)
        } else {
            ("Disabled", LitheTheme.secondaryText)
        }
        return Text(LocalizedStringKey(title))
            .font(LitheTheme.uiFont(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LitheTheme.ActionButton.spacing) { actionButtonContent }
                .fixedSize()
            VStack(alignment: .leading, spacing: LitheTheme.ActionButton.spacing) { actionButtonContent }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var actionButtonContent: some View {
        Button(LocalizedStringKey(isEnabled ? "Disable" : "Enable"), action: actions.toggleEnabled)
            .buttonStyle(LitheActionButtonStyle(isPrimary: true))
            .disabled(isApplyingChanges || isBusy || plugin.isRequired)
            .accessibilityIdentifier("plugin-detail-toggle")
        if let update = actions.update, let updateVersion {
            let title = String(
                format: PluginMarketplacePresentation.localized("Update to %@", locale: locale), updateVersion
            )
            // Keep the full version when it fits; a single long version must not
            // defeat the vertical fallback in the 160pt detail pane.
            ViewThatFits(in: .horizontal) {
                Button(title, action: update).buttonStyle(LitheActionButtonStyle())
                Button("Update", action: update).buttonStyle(LitheActionButtonStyle())
            }
            .help(title)
            .accessibilityValue(updateVersion)
            .accessibilityIdentifier("plugin-detail-update")
            .disabled(isApplyingChanges || isBusy)
        }
        if let reinstall = actions.reinstall {
            Button(LocalizedStringKey("Reinstall"), action: reinstall)
                .buttonStyle(LitheActionButtonStyle())
                .disabled(isApplyingChanges || isBusy)
                .accessibilityIdentifier("plugin-detail-reinstall")
        }
        if let restore = actions.restore {
            Button(LocalizedStringKey("Restore"), action: restore)
                .buttonStyle(LitheActionButtonStyle())
                .disabled(isApplyingChanges || isBusy)
                .accessibilityIdentifier("plugin-detail-remove")
        } else if let uninstall = actions.uninstall {
            Button(LocalizedStringKey("Uninstall"), action: uninstall)
                .buttonStyle(LitheActionButtonStyle())
                .disabled(isApplyingChanges || isBusy || plugin.isRequired)
                .accessibilityIdentifier("plugin-detail-remove")
        }
        if plugin.hasChangesPendingRestart {
            RestartLitheButton(prominent: false)
                .accessibilityIdentifier("plugin-detail-restart")
        }
        if isBusy { ProgressView().controlSize(.small) }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        let items = noticeItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    Label(item.text, systemImage: item.systemImage)
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(item.isError ? LitheTheme.error : LitheTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill((item.isError ? LitheTheme.error : LitheTheme.warning).opacity(0.08))
                        )
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 10)
        }
    }

    private struct Notice {
        let text: String
        let systemImage: String
        var isError = false
    }

    private var noticeItems: [Notice] {
        var items: [Notice] = []
        if let error {
            items.append(Notice(text: error, systemImage: "exclamationmark.triangle.fill", isError: true))
        }
        if let replacementID = OfficialPluginCatalog.entry(for: plugin.id)?.communityReplacementID {
            // The old package keeps its language until the next launch
            // removes it, so the community version is installed after
            // that restart, not beside the old one.
            let uninstalling = plugin.installationStatus == .uninstallPending
            items.append(Notice(
                text: String(
                    format: localized(uninstalling
                        ? "Restart Lithe to finish uninstalling %@, then install the community plugin %@ from the Marketplace."
                        : "%@ is no longer an official plugin. It moved to the community plugin %@ in Lithe Store and gets no further updates here. Uninstall it, restart Lithe, then install the community version from the Marketplace."),
                    plugin.manifest.displayName,
                    replacementID.rawValue
                ),
                systemImage: "arrow.triangle.branch"
            ))
        }
        if plugin.origin == .community {
            items.append(Notice(
                text: localized(plugin.disk == nil
                    ? "Community plugin maintained by a third party. Report plugin problems in its own repository."
                    : "Community plugin installed from disk. Its publisher and repository have not been verified."),
                systemImage: "person.2"
            ))
        }
        if plugin.origin == .localDevelopment {
            items.append(Notice(
                text: localized("Unsigned development package. Release builds of Lithe will not load it."),
                systemImage: "hammer",
                isError: true
            ))
        }
        return items
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(PluginDetailTab.allCases, id: \.self) { value in
                    tabButton(value)
                }
            }
            .padding(.horizontal, 22)
        }
    }

    private func count(for tab: PluginDetailTab) -> Int? {
        let value: Int = switch tab {
        case .overview, .versions: 0
        case .features: plugin.capabilities.count
        case .settings: plugin.settings.count + plugin.contributions.actions.count
        case .permissions: plugin.permissions.count + (plugin.programs?.count ?? 0)
        }
        return value > 0 ? value : nil
    }

    private func tabButton(_ value: PluginDetailTab) -> some View {
        let isSelected = tab == value
        return Button {
            tab = value
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    Text(LocalizedStringKey(value.title))
                        .font(LitheTheme.uiFont(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    if let count = count(for: value) {
                        Text(verbatim: "\(count)")
                            .font(LitheTheme.uiFont(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(LitheTheme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(LitheTheme.badgeBackground))
                    }
                }
                .fixedSize()
                Rectangle()
                    .fill(isSelected ? LitheTheme.accent : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.litheNoPress)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .overview: overview
        case .features: features
        case .settings: settings
        case .permissions: permissions
        case .versions: versions
        }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: summary)
                .foregroundStyle(LitheTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
                infoRow("Status") {
                    Text(LocalizedStringKey(hasPendingChange ? "Pending confirmation" : plugin.statusMessage))
                }
                if !plugin.capabilities.isEmpty {
                    infoRow("Provides") {
                        Text(verbatim: providedKinds)
                    }
                }
                infoRow("Plugin Source") { sourceDescription }
                infoRow("Settings") {
                    let settingCount = plugin.settings.count + plugin.contributions.actions.count
                    if settingCount == 0 {
                        Text(LocalizedStringKey("None"))
                    } else {
                        HStack(spacing: 6) {
                            Text(verbatim: "\(settingCount)")
                            linkButton("View") { tab = .settings }
                        }
                    }
                }
            }
            .font(LitheTheme.settingsFont)
            let destinations = settingsDestinations
            if !destinations.isEmpty {
                LitheSettingsSection("Configure in Settings") {
                    ForEach(destinations, id: \.category) { destination in
                        HStack(spacing: 8) {
                            Image(systemName: destination.category.icon)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .frame(width: 16)
                            Text(verbatim: destination.subjects)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            linkButton(destination.label) { actions.openSettings(destination.category) }
                        }
                    }
                }
            }
        }
    }

    private var providedKinds: String {
        var seen = Set<PluginCapability.Kind>()
        return plugin.capabilities
            .filter { seen.insert($0.kind).inserted }
            .map { localized(Self.kindTitle($0.kind)) }
            .joined(separator: localized(", "))
    }

    @ViewBuilder private var sourceDescription: some View {
        if let disk = plugin.disk {
            HStack(spacing: 6) {
                Text(LocalizedStringKey("Installed from Disk"))
                Text(verbatim: disk.fileName)
                    .font(LitheTheme.uiFont(size: 12, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .textSelection(.enabled)
            }
        } else if let sourceName {
            HStack(spacing: 6) {
                Text(String(format: localized("Installed from %@"), sourceName))
                repositoryLink
            }
        } else {
            switch plugin.origin {
            case .localDevelopment: Text(LocalizedStringKey("Local development package"))
            default: Text(LocalizedStringKey("Ships with Lithe"))
            }
        }
    }

    @ViewBuilder private var repositoryLink: some View {
        if let repository = plugin.marketplace?.repository, let url = URL(string: repository) {
            Link(destination: url) {
                Label(LocalizedStringKey("Source Repository"), systemImage: "arrow.up.right.square")
            }
        }
    }

    private struct SettingsDestination {
        let category: SettingsCategory
        let label: String
        let subjects: String
    }

    /// Settings pages that already configure what this plugin provides.
    private var settingsDestinations: [SettingsDestination] {
        func titles(_ kinds: Set<PluginCapability.Kind>) -> String {
            var seen = Set<String>()
            return plugin.capabilities
                .filter { kinds.contains($0.kind) && seen.insert($0.title).inserted }
                .map(\.title)
                .joined(separator: localized(", "))
        }
        var destinations: [SettingsDestination] = []
        let servers = titles([.languageServer])
        if !servers.isEmpty {
            destinations.append(SettingsDestination(category: .lsp, label: SettingsCategory.lsp.title, subjects: servers))
        }
        let runnable = titles([.run, .test])
        if !runnable.isEmpty {
            destinations.append(SettingsDestination(category: .run, label: SettingsCategory.run.title, subjects: runnable))
        }
        return destinations
    }

    // MARK: Features

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                LitheInfoTip(LocalizedStringKey("Generated from the plugin's declaration."))
            }
            if plugin.capabilities.isEmpty {
                emptyTab("This plugin declares no features.")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(plugin.capabilities) { capability in
                        capabilityCard(capability)
                    }
                }
            }
        }
    }

    private func capabilityCard(_ capability: PluginCapability) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(Self.kindTitle(capability.kind)))
                .font(LitheTheme.uiFont(size: 11, weight: .medium))
                .foregroundStyle(LitheTheme.secondaryText)
            Text(verbatim: capability.title)
                .font(LitheTheme.settingsStrongFont)
                .lineLimit(1)
            if let detail = detailText(capability.detail) {
                Text(verbatim: detail)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(LocalizedStringKey(capabilityStatus))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(isEnabled && !plugin.hasChangesPendingRestart ? LitheTheme.success : LitheTheme.secondaryText)
                Spacer(minLength: 4)
                if isEnabled, let category = Self.settingsCategory(for: capability.kind) {
                    linkButton("Configure") { actions.openSettings(category) }
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(LitheTheme.settingsControlBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(LitheTheme.settingsControlBorder, lineWidth: 1))
    }

    private var capabilityStatus: String {
        if plugin.hasChangesPendingRestart { return "Takes effect after Lithe restarts" }
        return isEnabled ? "Available" : "Plugin disabled"
    }

    private func detailText(_ detail: PluginCapability.Detail) -> String? {
        switch detail {
        case .none: nil
        case .fileTypes(let types): types.joined(separator: " ")
        case .packagedServer: localized("Inside the plugin")
        case .runtimeServer(let tool, let packagedRuntime):
            String(format: localized(packagedRuntime ? "Runs on %@ shipped with the plugin" : "Runs on %@ installed on this Mac"), tool)
        case .systemServer(let commands):
            String(format: localized("Installed on this Mac: %@"), commands.joined(separator: " | "))
        case .hostIntegration: localized("Provided by Lithe for this language")
        case .tasks(let count): String(format: localized("Tasks: %d"), count)
        }
    }

    static func kindTitle(_ kind: PluginCapability.Kind) -> String {
        switch kind {
        case .language: "Language"
        case .languageServer: "Language Server"
        case .run: "Run"
        case .test: "Test"
        case .debug: "Debugger"
        case .buildSystem: "Build System"
        case .toolWindow: "Tool Window"
        case .command: "Command"
        }
    }

    static func settingsCategory(for kind: PluginCapability.Kind) -> SettingsCategory? {
        switch kind {
        case .languageServer: .lsp
        case .run, .test: .run
        default: nil
        }
    }

    // MARK: Settings

    @ViewBuilder private var settings: some View {
        if plugin.settings.isEmpty && plugin.contributions.actions.isEmpty {
            emptyTab("This plugin declares no settings.")
        } else {
            PluginSettingsSection(
                settings: plugin.settings,
                actions: plugin.contributions.actions,
                hasProject: actions.hasProject,
                handlers: actions.settings
            )
        }
    }

    // MARK: Permissions & Programs

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 4) {
            LitheSettingsSection("Permissions") {
                if plugin.permissions.isEmpty {
                    Text(LocalizedStringKey("Needs no extra permissions."))
                        .foregroundStyle(LitheTheme.secondaryText)
                } else {
                    ForEach(plugin.permissions, id: \.self) { permission in
                        HStack(spacing: 8) {
                            Label(
                                PluginMarketplacePresentation.permissionDescription(permission, locale: locale),
                                systemImage: "checkmark.shield"
                            )
                            Text(verbatim: permission)
                                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                    }
                }
            }
            LitheSettingsSection("Programs it can run") {
                if let programs = plugin.programs {
                    if programs.isEmpty {
                        Text(LocalizedStringKey("Starts no programs."))
                            .foregroundStyle(LitheTheme.secondaryText)
                    } else {
                        ForEach(programs, id: \.self) { program in
                            programRow(program)
                        }
                    }
                } else {
                    Text(LocalizedStringKey("Part of Lithe. It starts no programs of its own."))
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
            Text(LocalizedStringKey("Setting values only fill the places the program templates reserve for them, so changing a setting never changes the programs above."))
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }

    private func programRow(_ program: PluginProgram) -> some View {
        let description = PluginMarketplacePresentation.programDescription(program, locale: locale)
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: description.title)
            if !description.detail.isEmpty {
                Text(verbatim: description.detail)
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(LitheTheme.settingsControlBackground))
            }
            DisclosureGroup(LocalizedStringKey("Full Program Declaration")) {
                Text(verbatim: (try? program.canonicalJSON()) ?? "")
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(LitheTheme.smallFont)
        }
        .padding(.bottom, 6)
    }

    // MARK: Versions & Source

    private var versions: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
            infoRow("Current Version") { Text(verbatim: plugin.manifest.version.description) }
            infoRow("Previous Version") {
                if let previous = plugin.previousVersion {
                    HStack(spacing: 8) {
                        Text(verbatim: previous.description)
                        if let rollback = actions.rollback {
                            linkButton("Roll Back…", showsArrow: false, action: rollback)
                                .disabled(isApplyingChanges || isBusy)
                        }
                    }
                } else {
                    Text(verbatim: "—")
                }
            }
            infoRow("Updates") {
                if let sourceName {
                    Text(String(format: localized("Installed from %@. Updates only come from that repository."), sourceName))
                } else if plugin.disk != nil || plugin.origin == .localDevelopment {
                    Text(LocalizedStringKey("Managed outside the Marketplace; no update source."))
                } else {
                    Text(LocalizedStringKey("Updated with Lithe"))
                }
            }
            if let repository = plugin.marketplace?.repository, let url = URL(string: repository) {
                infoRow("Source Repository") {
                    Link(PluginMarketplacePresentation.repositoryName(repository), destination: url)
                }
            }
            if let disk = plugin.disk {
                infoRow("Local Package") { monospaced(disk.fileName) }
                if let archive = disk.archiveSHA256 {
                    infoRow("Archive SHA-256") { monospaced(archive) }
                }
            } else if let marketplace = plugin.marketplace {
                infoRow("Archive SHA-256") { monospaced(marketplace.archiveSHA256) }
            }
            if let contentDigest = plugin.disk?.contentDigest ?? plugin.marketplace?.contentDigest {
                infoRow("Content SHA-256") {
                    VStack(alignment: .leading, spacing: 2) {
                        monospaced(contentDigest)
                        Text(LocalizedStringKey("Checked again every time Lithe loads the plugin."))
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
            }
            if plugin.manifest.vendor.signatureRequirement == .publisherPackage {
                infoRow("Signature") { Text(LocalizedStringKey("Lithe publisher signature verified")) }
            }
            infoRow("Plugin ID") { monospaced(plugin.id.rawValue) }
        }
        .font(LitheTheme.settingsFont)
    }

    // MARK: Helpers

    private func infoRow<Content: View>(_ title: String, @ViewBuilder value: () -> Content) -> some View {
        GridRow {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .gridColumnAlignment(.leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func monospaced(_ value: String) -> some View {
        Text(verbatim: value)
            .font(LitheTheme.uiFont(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func linkButton(_ title: String, showsArrow: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(title)) + Text(verbatim: showsArrow ? " →" : "")
        }
        .buttonStyle(.link)
        .font(LitheTheme.smallFont)
    }

    private func emptyTab(_ message: String) -> some View {
        Text(LocalizedStringKey(message))
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 40)
    }

    private func localized(_ key: String) -> String {
        PluginMarketplacePresentation.localized(key, locale: locale)
    }
}

/// Keep resize measurement local: the plugin's content is built before entering
/// this reader. A native settings row retains its controls and can scroll when
/// the detail pane is narrower than the complete form.
private struct PluginDetailContent<Content: View>: View {
    let scrollsHorizontally: Bool
    let content: Content
    private let inset: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            ScrollView(scrollsHorizontally ? [.horizontal, .vertical] : .vertical) {
                content
                    .frame(minWidth: max(0, geometry.size.width - 2 * inset),
                           maxWidth: scrollsHorizontally ? nil : .infinity,
                           minHeight: max(0, geometry.size.height - 2 * inset), alignment: .topLeading)
                    .padding(inset)
            }
            .litheScrollViewChrome()
        }
    }
}
