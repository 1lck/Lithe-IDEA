import SwiftUI
import LitheCoreContracts
import LitheModuleAPI

// Note: 插件市场的来源、信任与安装确认见 .agents/notes/implemented/feature/2026-10-12-plugin-marketplace.md

/// Settings › Plugins › Marketplace: plugins listed by the enabled plugin
/// repositories on the left, the selected plugin's details on the right.
struct PluginMarketplaceView: View {
    @Environment(\.locale) private var locale
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: PluginMarketplaceFeatureModel
    @State private var pluginListActive = false
    @State private var searchText = ""
    @State private var sourceFilter = PluginMarketplaceView.allSources
    @State private var sortOrder = PluginMarketplaceFeatureModel.SortOrder.name
    @State private var selectedPluginID: PluginID?
    @AppStorage("lithe.settings.pluginMarketplaceListWidth") private var listWidth = 320.0

    private static let allSources = ""

    private var listings: [PluginMarketplaceListing] {
        feature.visibleListings(
            query: searchText,
            sourceID: sourceFilter == Self.allSources ? nil : sourceFilter,
            sortOrder: sortOrder
        )
    }

    private var selectedListing: PluginMarketplaceListing? {
        listings.first { $0.pluginID == selectedPluginID } ?? listings.first
    }

    var body: some View {
        GeometryReader { geometry in
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: CGFloat(listWidth),
                minimum: PluginManagementView.listMinimumWidth,
                maximum: max(
                    PluginManagementView.listMinimumWidth,
                    geometry.size.width - SplitHandleView.thickness - PluginManagementView.detailMinimumWidth
                ),
                flexibleMinimum: PluginManagementView.detailMinimumWidth,
                onCommit: { listWidth = Double($0) },
                sized: { sidebar.background(LitheToolWindowActivityTracker(isActive: $pluginListActive)) },
                flexible: { detail }
            )
        }
        .task { await feature.refreshIfNeeded() }
    }

    // MARK: List

    private var sidebar: some View {
        VStack(spacing: 0) {
            LitheSettingsSearchField("Search plugins", text: $searchText)
                .padding(.horizontal, 8)
                .frame(height: 44)
            HStack(spacing: 8) {
                LitheSettingsSelect(
                    selection: $sourceFilter,
                    options: [Self.allSources] + feature.sources.filter(\.isEnabled).map(\.id),
                    width: 132,
                    accessibilityLabel: "Plugin repository",
                    title: { id in
                        id == Self.allSources
                            ? PluginMarketplacePresentation.localized("All Repositories", locale: locale)
                            : sourceName(id)
                    },
                    localizesTitles: false
                )
                Spacer(minLength: 4)
                LitheSettingsSelect(
                    selection: $sortOrder,
                    options: PluginMarketplaceFeatureModel.SortOrder.allCases,
                    width: 120,
                    accessibilityLabel: "Sort plugins",
                    title: { order in
                        switch order {
                        case .name: "Sort by Name"
                        case .lastUpdated: "Sort by Last Updated"
                        }
                    }
                )
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            if listings.isEmpty {
                emptyList
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(listings) { listing in
                            row(listing)
                        }
                    }
                }
                .litheScrollViewChrome()
            }
        }
        .frame(maxWidth: .infinity)
        .background(LitheTheme.settingsListSurface)
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            if feature.sourceStatuses.values.contains(where: \.isRefreshing) {
                ProgressView().controlSize(.small)
            }
            Text(LocalizedStringKey(searchText.isEmpty ? "No plugins available" : "No matching plugins"))
                .font(LitheTheme.settingsFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ listing: PluginMarketplaceListing) -> some View {
        let offer = feature.offer(for: listing)
        let isSelected = selectedListing?.pluginID == listing.pluginID
        return HStack(spacing: 10) {
            PluginMarketplaceIcon(entry: offer?.entry, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: offer?.entry.name ?? listing.pluginID.rawValue)
                    .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: offer.map { "\($0.entry.author) · \($0.entry.presentedVersion.version)" } ?? "")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let offer {
                rowAction(offer)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .litheSelectionRow(isSelected: isSelected, isFocused: pluginListActive)
        .contentShape(Rectangle())
        .onTapGesture { selectedPluginID = listing.pluginID }
        // Keep the row's Install button a separate element: combining the
        // children makes pressing the row install the plugin instead of
        // selecting it.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: offer?.entry.name ?? listing.pluginID.rawValue))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction { selectedPluginID = listing.pluginID }
    }

    @ViewBuilder
    private func rowAction(_ offer: PluginMarketplaceOffer) -> some View {
        let pluginID = PluginID(offer.entry.id)
        if feature.busyPluginIDs.contains(pluginID) {
            ProgressView().controlSize(.small)
        } else {
            switch feature.installState(for: offer) {
            case .installable:
                Button(LocalizedStringKey("Install")) { install(offer) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .updateAvailable:
                Button(LocalizedStringKey("Update")) { install(offer) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .installed, .installedFromOtherSource, .managedOutsideMarketplace:
                if feature.requiresRestart(pluginID) {
                    RestartLitheButton(prominent: false)
                } else {
                    Text(LocalizedStringKey("Installed"))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            case .unsupported:
                Text(LocalizedStringKey("Not Supported"))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            case .blockedByRetiredPlugin(_, let uninstallPending):
                if uninstallPending {
                    RestartLitheButton(prominent: false)
                } else {
                    Text(LocalizedStringKey("Replaces an Installed Plugin"))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.warning)
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let listing = selectedListing, let offer = feature.offer(for: listing) {
            ScrollView {
                PluginMarketplaceDetail(
                    feature: feature,
                    listing: listing,
                    offer: offer,
                    install: { install(offer) },
                    uninstall: { uninstall(listing.pluginID) }
                )
            }
            .litheScrollViewChrome()
            .background(LitheTheme.settingsSurface)
        } else {
            VStack(spacing: 10) {
                PluginMarketplaceIcon(entry: nil, size: 36)
                Text(LocalizedStringKey("Select a plugin"))
                    .font(LitheTheme.uiFont(size: 15, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LitheTheme.settingsSurface)
        }
    }

    private func install(_ offer: PluginMarketplaceOffer) {
        Task { @MainActor in
            await feature.install(offer)
            model.objectWillChange.send()
        }
    }

    private func uninstall(_ pluginID: PluginID) {
        Task { @MainActor in
            await model.uninstallPlugin(pluginID)
            model.objectWillChange.send()
        }
    }

    private func sourceName(_ id: String) -> String {
        guard let source = feature.sources.first(where: { $0.id == id }) else { return id }
        return PluginMarketplacePresentation.sourceName(source, locale: locale)
    }
}

/// Detail pane for one plugin: identity, install action, metadata DBX also
/// shows (version, license, release date, platforms, links), and the notice
/// about who maintains it.
private struct PluginMarketplaceDetail: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: PluginMarketplaceFeatureModel
    let listing: PluginMarketplaceListing
    let offer: PluginMarketplaceOffer
    let install: () -> Void
    let uninstall: () -> Void
    @State private var confirmingUninstall = false

    private var entry: PluginMarketplaceEntry { offer.entry }
    private var state: PluginMarketplaceInstallState { feature.installState(for: offer) }
    private var isBusy: Bool { feature.busyPluginIDs.contains(PluginID(entry.id)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let error = feature.errors[PluginID(entry.id)] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text(verbatim: tag)
                            .font(LitheTheme.smallFont)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(LitheTheme.settingsSelection)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            Text(verbatim: entry.description(for: locale))
                .font(LitheTheme.settingsFont)
                .foregroundStyle(LitheTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            metadata
            links
            maintainerNotice
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PluginMarketplaceIcon(entry: entry, size: 48)
            // The detail pane can be narrow inside Settings, so the name
            // wraps by words and the action sits below it instead of
            // squeezing the name from the side.
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: entry.name)
                    .font(LitheTheme.uiFont(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PluginTrustBadge(isOfficial: offer.source.isOfficial)
                    Text(verbatim: "\(entry.author) · \(PluginMarketplacePresentation.repositoryName(entry.repository))")
                        .font(LitheTheme.settingsFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                action
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var action: some View {
        if isBusy {
            ProgressView().controlSize(.small)
        } else {
            switch state {
            case .installable:
                Button(LocalizedStringKey("Install"), action: install)
                    .buttonStyle(.borderedProminent)
                    .tint(LitheTheme.accent)
            case .updateAvailable(_, let available):
                Button(String(format: PluginMarketplacePresentation.localized("Update to %@", locale: locale), available), action: install)
                    .buttonStyle(.borderedProminent)
                    .tint(LitheTheme.accent)
            case .installed, .installedFromOtherSource, .managedOutsideMarketplace:
                HStack(spacing: 8) {
                    if feature.requiresRestart(PluginID(entry.id)) {
                        RestartLitheButton()
                    } else {
                        Button(LocalizedStringKey("Installed")) {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    }
                    if feature.canUninstall(PluginID(entry.id)) {
                        Button(LocalizedStringKey("Uninstall")) { confirmingUninstall = true }
                            .buttonStyle(.bordered)
                    }
                }
                .confirmationDialog(
                    String(format: PluginMarketplacePresentation.localized("Uninstall %@?", locale: locale), entry.name),
                    isPresented: $confirmingUninstall,
                    titleVisibility: .visible
                ) {
                    Button(LocalizedStringKey("Uninstall"), role: .destructive, action: uninstall)
                    Button(LocalizedStringKey("Cancel"), role: .cancel) {}
                } message: {
                    Text(LocalizedStringKey("The plugin will be removed after restarting Lithe."))
                }
            case .unsupported:
                Button(LocalizedStringKey("Not Supported")) {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            case .blockedByRetiredPlugin(_, let uninstallPending):
                HStack(spacing: 8) {
                    Button(LocalizedStringKey("Install")) {}
                        .buttonStyle(.bordered)
                        .disabled(true)
                    if uninstallPending { RestartLitheButton() }
                }
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            if listing.offers.count > 1 {
                metadataRow("Repository") {
                    sourcePicker
                }
            } else {
                metadataRow("Repository") {
                    Text(verbatim: PluginMarketplacePresentation.sourceName(offer.source, locale: locale))
                }
            }
            // Version facts describe what Install would actually install;
            // a newer release this Mac cannot use is named separately.
            let shown = entry.presentedVersion
            metadataRow("Version") { Text(verbatim: shown.version) }
            if entry.installableVersion != nil, entry.latestVersion != shown.version {
                metadataRow("Latest Version") {
                    Text(String(
                        format: PluginMarketplacePresentation.localized("%@ (not available for this Lithe or Mac)", locale: locale),
                        entry.latestVersion
                    ))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            metadataRow("Release Date") { Text(verbatim: shown.releaseDate) }
            metadataRow("License") { Text(verbatim: entry.license) }
            metadataRow("Platforms") {
                Text(verbatim: shown.platforms.map(PluginMarketplacePresentation.platformName).joined(separator: ", "))
            }
            stateMessage
        }
        .font(LitheTheme.settingsFont)
    }

    @ViewBuilder private var stateMessage: some View {
        switch state {
        case .blockedByRetiredPlugin(let name, let uninstallPending):
            Label(
                String(
                    format: PluginMarketplacePresentation.localized(
                        uninstallPending
                            ? "Restart Lithe to finish uninstalling %@, then install this plugin."
                            : "Uninstall %@ from the Installed tab and restart Lithe first. It is the retired official version of this plugin and supports the same language.",
                        locale: locale
                    ),
                    name
                ),
                systemImage: "arrow.triangle.branch"
            )
            .foregroundStyle(LitheTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        case .unsupported(let message):
            Label(
                PluginMarketplacePresentation.unsupportedMessage(entry: entry, platform: feature.platform, fallback: message, locale: locale),
                systemImage: "nosign"
            )
            .foregroundStyle(LitheTheme.warning)
        case .installedFromOtherSource(let sourceName):
            Label(
                String(format: PluginMarketplacePresentation.localized("Installed from %@. Updates only come from that repository.", locale: locale), sourceName),
                systemImage: "info.circle"
            )
            .foregroundStyle(LitheTheme.secondaryText)
        case .managedOutsideMarketplace(let version):
            Label(
                String(format: PluginMarketplacePresentation.localized("Version %@ is built in or installed from disk.", locale: locale), version),
                systemImage: "info.circle"
            )
            .foregroundStyle(LitheTheme.secondaryText)
        case .installed(let version):
            if feature.requiresRestart(PluginID(entry.id)) {
                Label(
                    String(format: PluginMarketplacePresentation.localized("Version %@ is installed. Restart Lithe to load it.", locale: locale), version),
                    systemImage: "arrow.clockwise.circle"
                )
                .foregroundStyle(LitheTheme.warning)
            } else {
                Label(
                    String(format: PluginMarketplacePresentation.localized("Version %@ is installed.", locale: locale), version),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(LitheTheme.success)
            }
        case .updateAvailable(let installed, _):
            Label(
                String(format: PluginMarketplacePresentation.localized("Version %@ is installed.", locale: locale), installed),
                systemImage: "arrow.up.circle"
            )
            .foregroundStyle(LitheTheme.secondaryText)
        case .installable:
            EmptyView()
        }
    }

    private var sourcePicker: some View {
        LitheSettingsSelect(
            selection: Binding(
                get: { offer.source.id },
                set: { feature.selectedSourceIDs[listing.pluginID] = $0 }
            ),
            options: listing.offers.map(\.source.id),
            width: 180,
            accessibilityLabel: "Install from repository",
            title: { id in
                listing.offers.first { $0.source.id == id }
                    .map { PluginMarketplacePresentation.sourceName($0.source, locale: locale) } ?? id
            },
            localizesTitles: false
        )
        // Updates come only from the source the plugin was installed from.
        .disabled(feature.installedSourceID(for: listing.pluginID) != nil)
    }

    private var links: some View {
        HStack(spacing: 16) {
            if let url = URL(string: entry.repository) {
                Link(destination: url) {
                    Label(LocalizedStringKey("Source Repository"), systemImage: "arrow.up.right.square")
                }
            }
            if let homepage = entry.homepage, let url = URL(string: homepage) {
                Link(destination: url) {
                    Label(LocalizedStringKey("Homepage"), systemImage: "arrow.up.right.square")
                }
            }
        }
        .font(LitheTheme.settingsFont)
    }

    private var maintainerNotice: some View {
        LitheBanner(status: .infoMuted) {
            Text(offer.source.isOfficial
                 ? PluginMarketplacePresentation.localized("This plugin is maintained and signed by Lithe. Report problems in the source repository.", locale: locale)
                 : PluginMarketplacePresentation.localized("This plugin is maintained by a community developer, not by Lithe. Lithe verified that the download matches the plugin repository, and will show what the plugin can run before installing it. Report problems with the plugin in its own repository.", locale: locale))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metadataRow<Content: View>(_ title: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 96, alignment: .leading)
            value()
                .textSelection(.enabled)
        }
    }
}

struct PluginTrustBadge: View {
    let isOfficial: Bool

    var body: some View {
        Text(LocalizedStringKey(isOfficial ? "Official" : "Community"))
            .font(LitheTheme.uiFont(size: 10, weight: .semibold))
            .foregroundStyle(isOfficial ? LitheTheme.accent : LitheTheme.warning)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isOfficial ? LitheTheme.accent : LitheTheme.warning, lineWidth: 1)
            )
    }
}

/// Plugin icon from the index, limited by Core to the plugin's own
/// repository, with IDEA's plugin node icon as the fallback.
struct PluginMarketplaceIcon: View {
    let entry: PluginMarketplaceEntry?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = entry?.icon, let url = URL(string: icon) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().interpolation(.high).scaledToFit()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
    }

    private var fallback: some View {
        LitheIDEAIcon(
            resourcePath: "expui/nodes/plugin.svg",
            size: size * 0.75,
            fallbackSystemImage: "puzzlepiece.extension",
            preservesOriginalColors: true
        )
        .frame(width: size, height: size)
    }
}

enum PluginMarketplacePresentation {
    /// Looks up `key` in the app's chosen interface language rather than the
    /// system language, which `NSLocalizedString` would use.
    static func localized(_ key: String, locale: Locale) -> String {
        // `zh_CN` must find `zh-Hans.lproj`, so match like the system does.
        guard let language = Bundle.preferredLocalizations(
                  from: Bundle.main.localizations,
                  forPreferences: [locale.identifier]
              ).first,
              let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Readable name of an index platform such as `darwin-arm64`.
    static func platformName(_ platform: String) -> String {
        switch platform {
        case "darwin-arm64": "macOS (Apple Silicon)"
        case "darwin-x64": "macOS (Intel)"
        case "windows-x64": "Windows (x64)"
        case "windows-arm64": "Windows (ARM64)"
        default: platform
        }
    }

    static func sourceName(_ source: PluginMarketplaceSource, locale: Locale) -> String {
        source.isOfficial
            ? PluginMarketplacePresentation.localized("Lithe Official", locale: locale)
            : source.name
    }

    /// `owner/repo` of a GitHub repository URL.
    static func repositoryName(_ repository: String) -> String {
        guard let url = URL(string: repository) else { return repository }
        return url.pathComponents.filter { $0 != "/" }.prefix(2).joined(separator: "/")
    }

    static func unsupportedMessage(entry: PluginMarketplaceEntry, platform: String, fallback: String, locale: Locale) -> String {
        if case .unsupported(let code, let platform, _) = entry.availability {
            if code == "plugin.index.apiUnsupported" {
                return PluginMarketplacePresentation.localized("This plugin requires a newer version of Lithe.", locale: locale)
            }
            return String(format: PluginMarketplacePresentation.localized("Not supported on %@ yet.", locale: locale), platformName(platform))
        }
        return fallback
    }

    static func permissionDescription(_ permission: String, locale: Locale) -> String {
        switch permission {
        case "languageServer.launch":
            PluginMarketplacePresentation.localized("Start a language server when you open files of its language", locale: locale)
        case "process.run":
            PluginMarketplacePresentation.localized("Run your files", locale: locale)
        case "ui.contribute":
            PluginMarketplacePresentation.localized("Add tool windows and commands to the workbench", locale: locale)
        case "ui.web":
            PluginMarketplacePresentation.localized("Show its own page in a tool window", locale: locale)
        case "process.test":
            PluginMarketplacePresentation.localized("Run your tests", locale: locale)
        default:
            permission
        }
    }

    /// Title and the exact command lines a program runs. Every argument the
    /// approval covers is shown, so a changed template is visible when an
    /// update asks for approval again.
    static func programDescription(_ program: PluginProgram, locale: Locale) -> (title: String, detail: String) {
        let language = program.languageID ?? ""
        func line(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: " ") }
        func labeled(_ key: String, _ parts: [String]) -> String {
            String(format: localized(key, locale: locale), line(parts))
        }
        func serverDetail(_ command: [String]) -> String {
            var lines = [line(command + program.arguments)]
            if !program.validationArguments.isEmpty {
                lines.append(labeled("Check: %@", [command.first ?? ""] + program.validationArguments))
            }
            return lines.joined(separator: "\n")
        }
        let executable = program.executable ?? ""
        switch program.kind {
        case .packagedLanguageServer:
            return (
                String(format: localized("%@ language server (inside the plugin)", locale: locale), language),
                serverDetail([program.path ?? ""])
            )
        case .systemLanguageServer:
            return (
                String(format: localized("%@ language server (installed on this Mac)", locale: locale), language),
                serverDetail([program.commands.joined(separator: " | ")])
            )
        case .runtime:
            return (
                localized("Runtime used by the language server (installed on this Mac)", locale: locale),
                program.tool ?? ""
            )
        case .run:
            return (
                String(format: localized("Runs %@ files", locale: locale), language),
                line([executable] + program.argumentTemplate("arguments"))
            )
        case .test:
            return (
                String(format: localized("Runs %@ tests", locale: locale), language),
                [
                    labeled("All tests: %@", [executable] + program.argumentTemplate("workspaceArguments")),
                    labeled("One file: %@", [executable] + program.argumentTemplate("fileArguments")),
                    labeled("One test: %@", [executable] + program.argumentTemplate("testCaseArguments")),
                ].joined(separator: "\n")
            )
        case .buildSystem:
            var lines = [line([program.buildExecutables.joined(separator: " | ")])]
            let tasks = program.buildTaskIDs
            if !tasks.isEmpty {
                lines.append(labeled("Tasks: %@", [tasks.joined(separator: ", ")]))
            }
            return (
                String(format: localized("Builds %@ projects", locale: locale), program.buildSystemID ?? ""),
                lines.joined(separator: "\n")
            )
        case .unknown:
            // The full declaration stays behind the disclosure below so an
            // unfamiliar kind cannot push the sheet's buttons off screen.
            return (localized("Program", locale: locale), program.rawKind ?? "")
        }
    }
}

/// Confirmation for a community package: source, verified checksum,
/// permissions, and every program it can start. Cancel is the default.
struct PluginInstallConfirmationSheet: View {
    @Environment(\.locale) private var locale
    let confirmation: PluginInstallConfirmation
    let confirm: () -> Void
    let cancel: () -> Void

    private var review: PluginInstallReview { confirmation.review }
    private var newPrograms: Set<PluginProgram> { Set(review.newPrograms) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(
                format: PluginMarketplacePresentation.localized(confirmation.isUpdate ? "Update community plugin “%@”?" : "Install community plugin “%@”?", locale: locale),
                confirmation.displayName
            ))
            .font(LitheTheme.uiFont(size: 16, weight: .semibold))

            ScrollView {
                confirmationDetails
            }
            .frame(maxHeight: 480)

            HStack {
                Spacer()
                // Cancel is the default so pressing Return never installs.
                Button(LocalizedStringKey("Cancel"), action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button(LocalizedStringKey(confirmation.isUpdate ? "Update" : "Install"), action: confirm)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onExitCommand(perform: cancel)
    }

    private var confirmationDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                switch confirmation.package {
                case .marketplace(_, let entry, let sourceName):
                    infoRow("Source Repository", PluginMarketplacePresentation.repositoryName(entry.repository))
                    infoRow("Listed in", sourceName)
                    HStack(spacing: 12) {
                        Text(LocalizedStringKey("SHA-256"))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .frame(width: 140, alignment: .leading)
                        Label(LocalizedStringKey("Matches the plugin repository"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(LitheTheme.success)
                    }
                case .disk(let prepared):
                    infoRow("Local Package", prepared.provenance.fileName)
                    if let checksum = prepared.provenance.archiveSHA256 {
                        infoRow("Archive SHA-256", checksum)
                    }
                    infoRow("Content SHA-256", prepared.provenance.contentDigest)
                    Text(LocalizedStringKey("Selected from disk. The publisher and repository have not been verified."))
                        .foregroundStyle(LitheTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                infoRow("Author", confirmation.author)
                infoRow("Version", review.version)
            }
            .font(LitheTheme.settingsFont)

            section("Permissions") {
                ForEach(review.permissions, id: \.self) { permission in
                    Label(PluginMarketplacePresentation.permissionDescription(permission, locale: locale), systemImage: "checkmark.shield")
                }
            }

            section(confirmation.isUpdate ? "Programs (changes are highlighted)" : "Programs it can run") {
                ForEach(review.programs, id: \.self) { program in
                    let description = PluginMarketplacePresentation.programDescription(program, locale: locale)
                    let isNew = confirmation.isUpdate && newPrograms.contains(program)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: description.title)
                            if isNew {
                                Text(LocalizedStringKey("New"))
                                    .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                                    .foregroundStyle(LitheTheme.warning)
                            }
                        }
                        Text(verbatim: description.detail)
                            .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        DisclosureGroup(LocalizedStringKey("Full Program Declaration")) {
                            Text(verbatim: (try? program.canonicalJSON()) ?? "")
                                .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Label(
                LocalizedStringKey("Community plugins are maintained by third parties and can run the programs above on your Mac. Only install plugins you trust."),
                systemImage: "exclamationmark.triangle"
            )
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 140, alignment: .leading)
            Text(verbatim: value).textSelection(.enabled)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(LitheTheme.uiFont(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6, content: content)
                .font(LitheTheme.settingsFont)
        }
    }
}

/// Manage Plugin Repositories…: add, refresh, enable, and remove sources.
struct PluginRepositoriesSheet: View {
    @Environment(\.locale) private var locale
    @ObservedObject var feature: PluginMarketplaceFeatureModel
    let close: () -> Void
    @State private var newSource = ""
    @State private var isAdding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey("Plugin Repositories"))
                .font(LitheTheme.uiFont(size: 16, weight: .semibold))
            Text(LocalizedStringKey("Paste an https plugin index URL or a GitHub repository URL. A GitHub repository must contain lithe-plugin-index.json at its root."))
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(
                    LocalizedStringKey("https://github.com/owner/repository"),
                    text: $newSource
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                Button {
                    add()
                } label: {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(LocalizedStringKey("Add"))
                    }
                }
                .disabled(isAdding || newSource.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(feature.sources) { source in
                        sourceRow(source)
                        Rectangle().fill(LitheTheme.divider).frame(height: 1)
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)
            HStack {
                Button(LocalizedStringKey("Refresh All")) {
                    Task { await feature.refreshAll() }
                }
                Spacer()
                Button(LocalizedStringKey("Done"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear { feature.loadIfNeeded() }
    }

    private func sourceRow(_ source: PluginMarketplaceSource) -> some View {
        let status = feature.sourceStatuses[source.id] ?? .init()
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { source.isEnabled },
                set: { enabled in
                    perform { try feature.setSourceEnabled(enabled, sourceID: source.id) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: PluginMarketplacePresentation.sourceName(source, locale: locale))
                        .font(LitheTheme.uiFont(size: 13, weight: .semibold))
                    PluginTrustBadge(isOfficial: source.isOfficial)
                }
                Text(verbatim: source.indexURL)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(verbatim: statusText(status))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(status.error == nil ? LitheTheme.secondaryText : LitheTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if status.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await feature.refresh(sourceID: source.id) }
                } label: {
                    LitheIDEAIcon(resourcePath: "actions/refresh.svg", size: 16, fallbackSystemImage: "arrow.clockwise")
                }
                .litheToolbarIconButton(isEnabled: source.isEnabled)
                .disabled(!source.isEnabled)
                .help("Refresh")
            }
            if !source.isOfficial {
                Button(LocalizedStringKey("Remove")) {
                    perform { try feature.removeSource(source.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
    }

    private func statusText(_ status: PluginMarketplaceFeatureModel.SourceStatus) -> String {
        var parts: [String] = []
        if let fetchedAt = status.fetchedAt {
            parts.append(String(
                format: PluginMarketplacePresentation.localized("Refreshed %@", locale: locale),
                fetchedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            ))
        } else {
            parts.append(PluginMarketplacePresentation.localized("Not refreshed yet", locale: locale))
        }
        if !status.rejectedEntries.isEmpty {
            parts.append(String(
                format: PluginMarketplacePresentation.localized("Ignored entries: %lld", locale: locale),
                status.rejectedEntries.count
            ))
        }
        if let error = status.error {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }

    private func add() {
        let input = newSource
        guard !isAdding, !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isAdding = true
        error = nil
        Task { @MainActor in
            do {
                try await feature.addSource(input)
                newSource = ""
            } catch {
                self.error = error.localizedDescription
            }
            isAdding = false
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
