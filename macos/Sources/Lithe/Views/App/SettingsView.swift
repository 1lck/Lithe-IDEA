import AppKit
import ImageIO
import SwiftUI
import LitheCoreContracts
import LitheGitModule
import LitheModuleAPI

@MainActor
final class SettingsViewState: ObservableObject {
    @Published var selection: SettingsCategory
    @Published var searchQuery = ""
    @Published var hiddenPathPatternsDraft = ""
    @Published var aiAPIKeyDraft = ""
    /// Provider shown in Settings › AI Providers; independent of the one
    /// commit messages use.
    @Published var editingProviderID: UUID?
    @Published var isFormatPickerPresented = false
    @Published var detectedTerminalShells: [String] = []
    @Published var knownTerminalShells: [String] = []
    /// Monospaced families offered by Settings › Editor › Font. Discovered once
    /// per settings window because enumerating and measuring system fonts is
    /// expensive; the catalog itself caches the result for the process.
    @Published var editorFontFamilies: [String] = []
    @Published var pendingPluginEnabledStates: [PluginID: Bool] = [:]
    /// A page plugins registered, shown instead of `selection` while set.
    @Published var contributedPageID: ContributedSettingsPage.ID?
    /// A plugin another page asked Settings › Plugins to show.
    @Published var requestedPluginID: PluginID?
    @Published private(set) var isApplyingPluginChanges = false

    init(initialCategory: SettingsCategory) {
        selection = initialCategory
    }

    func showPlugin(_ pluginID: PluginID) {
        requestedPluginID = pluginID
        contributedPageID = nil
        selection = .plugins
    }

    func applyPluginChanges(
        _ apply: ([PluginID: Bool]) async -> Set<PluginID>
    ) async -> Bool {
        guard !isApplyingPluginChanges else { return false }
        guard !pendingPluginEnabledStates.isEmpty else { return true }
        isApplyingPluginChanges = true
        let applied = await apply(pendingPluginEnabledStates)
        for pluginID in applied {
            pendingPluginEnabledStates.removeValue(forKey: pluginID)
        }
        isApplyingPluginChanges = false
        return pendingPluginEnabledStates.isEmpty
    }
}

struct SettingsView: View {
    @FocusState private var isSearchFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    @EnvironmentObject private var updateChecker: UpdateChecker
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewState: SettingsViewState
    @AppStorage("lithe.settings.categorySidebarWidth") private var categorySidebarWidth = 234.0
    @State private var missingTerminalShellPath: String?
    @State private var expandedSidebarGroups: Set<String> = []
    /// Font shown before the latest font change, so the preview can compare the
    /// old and new faces for a moment instead of silently swapping glyphs.
    @State private var previousEditorFontFamily: String?
    @State private var lastEditorFontFamily: String?
    @State private var fontPreviewResetTask: Task<Void, Never>?
    let initialCategory: SettingsCategory
    /// Changes with every category request; see `WorkbenchFeatureModel.settingsCategoryRequest`.
    let categoryRequest: Int
    private let skillProjects: [URL]
    private let onDismiss: (() -> Void)?
    static let categoryMinimumWidth: CGFloat = 234
    static let contentMinimumWidth: CGFloat = 500
    static let categoryMaximumWidth: CGFloat = 480

    init(
        settings: AppSettings,
        viewState: SettingsViewState,
        initialCategory: SettingsCategory = .general,
        categoryRequest: Int = 0,
        skillProjects: [URL] = [],
        onDismiss: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.viewState = viewState
        self.initialCategory = initialCategory
        self.categoryRequest = categoryRequest
        self.skillProjects = skillProjects
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            // The split layout reserves the content minimum itself, so the
            // sidebar bound is a constant. Reading the window size here would
            // rebuild the sidebar and the whole page on every resize frame.
            LitheSplitPaneView(
                axis: .horizontal,
                placement: .leading,
                defaultSize: CGFloat(categorySidebarWidth),
                minimum: Self.categoryMinimumWidth,
                maximum: Self.categoryMaximumWidth,
                flexibleMinimum: Self.contentMinimumWidth,
                // The footer is 50pt plus its 1pt divider. Settings pages scroll
                // inside this known minimum instead of sizing the window.
                idealSize: CGSize(width: 900, height: 617),

                onCommit: { categorySidebarWidth = Double($0) },
                sized: { categories },
                flexible: {
                    content.simultaneousGesture(TapGesture().onEnded { isSearchFocused = false })
                }
            )
            Rectangle().fill(LitheTheme.settingsCardDivider).frame(height: 1)
            footer
        }
        .frame(minWidth: 900, minHeight: 668)
        .background {
            LitheTheme.settingsSurface
                .ignoresSafeArea()
        }
        .onAppear {
            SettingsPageLatencyTrace.installIfEnabled()
            expandGroup(containing: viewState.selection)
            syncVisibilityDrafts()
            model.refreshAIConfigurations()
            syncAIProviderDraft()
        }
        .onChange(of: settings.hiddenPathPatterns) { _ in syncVisibilityDrafts() }
        .onChange(of: settings.commitMessageAI.activeProviderID) { _ in syncAIProviderDraft() }
        .onChange(of: viewState.editingProviderID) { _ in syncAIProviderDraft() }
        .onChange(of: initialCategory) { category in
            viewState.searchQuery = ""
            viewState.selection = category
        }
        .onChange(of: categoryRequest) { _ in
            viewState.searchQuery = ""
            viewState.contributedPageID = nil
            viewState.selection = initialCategory
            expandGroup(containing: initialCategory)
        }
        .onChange(of: viewState.selection) { category in
            expandGroup(containing: category)
        }
        .onChange(of: viewState.searchQuery) { _ in
            if let page = selectedContributedPage {
                if filteredContributedPages.contains(where: { $0.id == page.id }) { return }
                viewState.contributedPageID = nil
            }
            guard !filteredCategories.contains(viewState.selection) else { return }
            if let firstMatch = filteredCategories.first {
                viewState.selection = firstMatch
            } else if let firstPage = filteredContributedPages.first {
                viewState.contributedPageID = firstPage.id
            }
        }
        .onChange(of: viewState.contributedPageID) { _ in
            expandSelectedContributedPageGroup()
        }
        .environment(\.locale, settings.language.locale)
        .font(LitheTheme.settingsFont)
        .alert("Shell not found", isPresented: Binding(
            get: { missingTerminalShellPath != nil },
            set: { if !$0 { missingTerminalShellPath = nil } }
        )) {
            Button("OK", role: .cancel) { missingTerminalShellPath = nil }
        } message: {
            if let missingTerminalShellPath {
                if missingTerminalShellPath.isEmpty {
                    Text("No default shell was detected. Choose a detected shell or run detection again.")
                } else {
                    Text("No shell was found at \(missingTerminalShellPath). Choose a detected shell or run detection again.")
                }
            }
        }
    }

    private var categories: some View {
        VStack(spacing: 0) {
            settingsSearchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

            LitheTreeList(nodes: categoryNodes, selection: Binding(
                get: { viewState.contributedPageID.map { "plugin:" + $0 } ?? "page:" + viewState.selection.id },
                set: { _ in }))

        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .background(LitheTheme.settingsSidebar)
    }

    private var settingsSearchField: some View {
        LitheSearchField("Search settings", text: $viewState.searchQuery, focus: $isSearchFocused)
            .accessibilityLabel("Search settings")
    }

    private var categoryNodes: [LitheTreeListNode] {
        // Plugin discovery can inspect settings and executables. Share one
        // current result among all groups in this sidebar construction.
        let contributedPages = filteredContributedPages
        let categories = filteredCategories
        return SettingsSidebarItem.layout.flatMap { item -> [LitheTreeListNode] in
            switch item {
            case .page(let category):
                return categories.contains(category) ? [categoryNode(category)] : []
            case .group(let group):
                let visible = group.categories.filter { categories.contains($0) }
                let pages = contributedPages.filter { $0.group == group }
                guard !visible.isEmpty || !pages.isEmpty else { return [] }
                return [LitheTreeListNode(id: "group:" + group.rawValue,
                    isExpanded: expandedSidebarGroups.contains(group.rawValue) || !viewState.searchQuery.isEmpty,
                    isSelectable: false, onExpansion: { expanded in
                        isSearchFocused = false
                        if expanded { expandedSidebarGroups.insert(group.rawValue) }
                        else { expandedSidebarGroups.remove(group.rawValue) }
                    }) {
                        HStack(spacing: 8) {
                            SettingsSidebarIcon(style: .group(group))
                            Text(LocalizedStringKey(group.rawValue)).font(LitheTheme.uiFont(size: 13, weight: .medium))
                        }
                    } children: {
                        group.entries.compactMap { entry -> LitheTreeListNode? in
                            switch entry {
                            case .page(let category):
                                return visible.contains(category) ? categoryNode(category, nested: true) : nil
                            case .subgroup(let subgroup):
                                return subgroupNode(subgroup, visible: visible)
                            }
                        } + pages.map { page in
                            LitheTreeListNode(id: "plugin:" + page.id, onSelect: {
                                isSearchFocused = false; viewState.contributedPageID = page.id
                            }) {
                                HStack(spacing: 6) {
                                    Text(verbatim: page.title).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(verbatim: page.contributions.map(\.pluginName).joined(separator: ", "))
                                        .font(LitheTheme.uiFont(size: 10)).foregroundStyle(LitheTheme.tertiaryText).lineLimit(1)
                                }
                            }
                        }
                    }]
            }
        }
    }

    private func subgroupNode(_ subgroup: SettingsSubgroup, visible: [SettingsCategory]) -> LitheTreeListNode? {
        let pages = subgroup.categories.filter { visible.contains($0) }
        guard !pages.isEmpty else { return nil }
        return LitheTreeListNode(id: "subgroup:" + subgroup.rawValue,
            isExpanded: expandedSidebarGroups.contains(subgroup.rawValue) || !viewState.searchQuery.isEmpty,
            isSelectable: false, onExpansion: { expanded in
                isSearchFocused = false
                if expanded { expandedSidebarGroups.insert(subgroup.rawValue) }
                else { expandedSidebarGroups.remove(subgroup.rawValue) }
            }) {
                Text(LocalizedStringKey(subgroup.rawValue)).font(LitheTheme.uiFont(size: 12.5))
            } children: {
                pages.map { categoryNode($0, nested: true) }
            }
    }

    private func categoryNode(_ category: SettingsCategory, nested: Bool = false) -> LitheTreeListNode {
        LitheTreeListNode(id: "page:" + category.id, onSelect: {
            SettingsPageLatencyTrace.selected(category.id)
            isSearchFocused = false; viewState.contributedPageID = nil; viewState.selection = category
        }) {
            HStack(spacing: 8) {
                if !nested { SettingsSidebarIcon(style: .page(category)) }
                Text(LocalizedStringKey(category.title)).font(LitheTheme.uiFont(size: nested ? 12.5 : 13))
            }
        }
    }

    private var contributedPages: [ContributedSettingsPage] {
        PluginSettingsRegistry.pages(from: model.pluginSnapshots)
    }

    private var selectedContributedPage: ContributedSettingsPage? {
        guard let id = viewState.contributedPageID else { return nil }
        return contributedPages.first { $0.id == id }
    }

    private var filteredContributedPages: [ContributedSettingsPage] {
        let query = viewState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return contributedPages }
        return contributedPages.filter { page in
            page.searchTerms.contains { term in
                term.localizedStandardContains(query) || localizedSearchValue(term).localizedStandardContains(query)
            }
        }
    }

    private func expandSelectedContributedPageGroup() {
        guard let page = selectedContributedPage else { return }
        // Keep the selected page lifetime outside SwiftUI's onChange closure;
        // Swift 6.3.3 crashes optimizing an optional group projection there.
        let groupID = page.group.rawValue
        expandedSidebarGroups.insert(groupID)
    }

    private func expandGroup(containing category: SettingsCategory) {
        if let group = category.group { expandedSidebarGroups.insert(group.rawValue) }
        if let subgroup = category.subgroup { expandedSidebarGroups.insert(subgroup.rawValue) }
    }

    private var filteredCategories: [SettingsCategory] {
        let query = viewState.searchQuery
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SettingsCategory.allCases
        }

        return SettingsCategory.allCases.filter { category in
            SettingsSearchVocabulary.matches(query: query, category: category) { localizedSearchValue($0) }
        }
    }

    private func localizedSearchValue(_ key: String) -> String {
        settings.language.localizedString(key)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if viewState.selection != .plugins || selectedContributedPage != nil {
                HStack(spacing: 8) {
                    ForEach(Array(settingsBreadcrumb.enumerated()), id: \.offset) { index, title in
                        if index > 0 {
                            Text(verbatim: "›")
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        let isLast = index == settingsBreadcrumb.count - 1
                        Text(LocalizedStringKey(title))
                            .font(isLast
                                  ? LitheTheme.uiFont(size: 14, weight: .semibold)
                                  : LitheTheme.uiFont(size: 13))
                            .foregroundStyle(isLast ? LitheTheme.primaryText : LitheTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(LitheTheme.settingsCard)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(LitheTheme.settingsCardDivider).frame(height: 1)
                }
            }

            settingsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LitheTheme.settingsPage)
    }

    private var settingsBreadcrumb: [String] {
        if let page = selectedContributedPage { return [page.group.rawValue, page.title] }
        let category = viewState.selection
        return [category.group?.rawValue, category.subgroup?.rawValue, category.title].compactMap { $0 }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if let page = selectedContributedPage {
            ContributedSettingsPageView(page: page, openPlugin: viewState.showPlugin)
                .id(page.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredCategories.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(LitheTheme.uiFont(size: 28, weight: .light))
                Text("No settings found")
                    .font(LitheTheme.uiFont(size: 15, weight: .medium))
                Text("Try a different search term.")
                    .font(LitheTheme.smallFont)
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewState.selection == .lsp {
            LSPControlCenterView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewState.selection == .run {
            RunConfigurationSettingsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewState.selection == .project {
            ProjectRuntimeSettingsView(feature: model.runtimeFeature)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewState.selection == .keymap {
            KeyboardShortcutSettingsView(
                feature: model.keyboardShortcutFeature,
                language: settings.language
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewState.selection == .plugins {
            PluginManagementView(settingsState: viewState)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch viewState.selection {
                    case .mcp:
                        McpServerLibraryView(
                            feature: model.mcpServerLibrary,
                            access: model.ideCapabilities,
                            workspaceURL: model.workspaceURL
                        )
                    case .general: generalSettings
                    case .editor: editorSettings
                    case .keymap: EmptyView()
                    case .terminal: terminalSettings
                    case .lsp: EmptyView()
                    case .project: EmptyView()
                    case .run: EmptyView()
                    case .ai: aiSettings
                    case .instructions:
                        AgentInstructionsSettingsView(feature: model.agentInstructionsFeature)
                    case .hooks:
                        AgentHooksSettingsView(feature: model.agentHooksFeature)
                    case .agents:
                        AgentPanelSettingsView(model: model, settings: settings, feature: model.agentManagementFeature)
                            .id(model.settingsCategoryRequest)
                    case .skills:
                        AgentSkillsSettingsView(feature: model.agentSkillsFeature, workspace: model.workspaceURL,
                            openProjects: skillProjects, preferredAgentID: model.selectedAgentConversationID,
                            onOpen: { model.platformUI.open($0) }, onReveal: { model.platformUI.revealInFileBrowser($0) },
                            onCopy: { model.platformUI.copyToClipboard($0) }, onChooseImport: { directory, title, prompt in
                                directory ? model.platformUI.chooseDirectory(title: title, prompt: prompt)
                                    : model.platformUI.chooseFile(title: title, prompt: prompt)
                            })
                    case .providers: providersSettings
                    case .git:
                        GitSettingsPage(settings: settings)
                    case .updates: updatesSettings
                    case .network: NetworkSettingsView(settings: settings)
                    case .processTermination: ProcessTerminationSettingsView(settings: settings)
                    case .diagnostics: diagnosticsSettings
                    case .plugins: EmptyView()
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 20)
                .padding(.bottom, 36)
                // Pages follow the window width; a cap here left a blank band on the right.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Appearance", info: "Choose a color theme and whether Lithe follows the system appearance.") {
                row("Color theme") {
                    LitheSettingsSelect(
                        selection: $settings.colorTheme,
                        options: AppColorTheme.allCases,
                        width: 190,
                        accessibilityLabel: "Color theme",
                        title: \AppColorTheme.title
                    )
                }

                row("Appearance mode") {
                    LitheSettingsSegmentedControl(
                        selection: $settings.themePreference,
                        options: AppThemePreference.allCases,
                        width: 260,
                        title: \AppThemePreference.title
                    )
                }

                LitheSettingsRow("Workbench background", info: "Shown across the entire workbench, including toolbars, project tree, editor, tabs, terminals, and status bar.") {
                    WorkbenchBackgroundThumbnail(feature: model.workbenchBackgroundFeature)

                    Button("Choose Image…") {
                        model.workbenchBackgroundFeature.chooseCustomImage()
                    }
                    .buttonStyle(LitheActionButtonStyle())

                    if settings.hasConfiguredWorkbenchBackground {
                        Button("Remove") {
                            model.workbenchBackgroundFeature.clear()
                        }
                        .buttonStyle(.litheNoPress)
                        .foregroundStyle(LitheTheme.accent)
                        .lithePointer()
                    }
                }

                WorkbenchBackgroundImageError(feature: model.workbenchBackgroundFeature)

                if settings.hasConfiguredWorkbenchBackground {
                    row("Workbench background opacity") {
                        Slider(value: $settings.workbenchBackgroundOpacity, in: 0.05...1.0, step: 0.01)
                            .frame(width: 180)
                        Text("\(Int((settings.workbenchBackgroundOpacity * 100).rounded()))%")
                            .foregroundStyle(LitheTheme.secondaryText)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }

            group("Language") {
                row("Language", info: "The interface language changes immediately. English is the default.") {
                    LitheSettingsSelect(
                        selection: $settings.language,
                        options: AppLanguage.allCases,
                        width: 190,
                        accessibilityLabel: "Language",
                        title: \AppLanguage.title
                    )
                }
            }

            group("Projects") {
                row("Open projects in", info: "Choose whether opening another project asks first, stays in this window, or creates a new window.") {
                    LitheSettingsSelect(
                        selection: $settings.projectOpenBehavior,
                        options: ProjectOpenBehavior.allCases,
                        width: 190,
                        accessibilityLabel: "Open projects in",
                        title: \ProjectOpenBehavior.title
                    )
                }
            }

            group("Files") {
                LitheSettingsCheckbox(
                    isOn: $settings.autoSave,
                    title: "Save changed files automatically"
                )
                if settings.autoSave {
                    row("Save after") {
                        LitheSettingsSelect(
                            selection: $settings.autoSaveDelay,
                            options: [0.5, 1.5, 3.0],
                            width: 150,
                            accessibilityLabel: "Save after",
                            title: autoSaveDelayTitle
                        )
                    }
                }
            }

            group("Hidden paths", info: "One pattern per line, case-insensitive. Patterns use wildcards, a simplified form of regular expressions: `*` matches any characters and `?` matches one.\nEnd a pattern with `/` or `/*` to hide a folder and everything in it; start with `**/` to match at any depth. Other patterns hide matching files.\nExamples:\n`**/dist/` — every dist folder\n`.lithe/*` — the .lithe folder in the project root\n`*.log` — all log files\n`docs/*.md` — Markdown files in docs\nThe built-in patterns below always apply.") {
                hiddenPathsEditor
            }
        }
    }

    /// One pattern list with the built-in patterns echoed beneath it, so the
    /// effective rules are visible without being editable.
    private var hiddenPathsEditor: some View {
        let builtIn = FileVisibilityRules.builtInPatterns
        let shown = builtIn.prefix(3)
        return VStack(alignment: .leading, spacing: 6) {
            LitheTextEditor(text: $viewState.hiddenPathPatternsDraft, height: 72)
                .accessibilityLabel(Text("Hidden paths"))
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("Built-in")
                        .font(LitheTheme.uiFont(size: 11))
                        .foregroundStyle(LitheTheme.tertiaryText)
                    ForEach(shown, id: \.self) { LitheSettingsPill(verbatim: $0, kind: .value) }
                    if builtIn.count > shown.count {
                        LitheSettingsPill(verbatim: "+\(builtIn.count - shown.count)")
                    }
                }
                .help(Text(verbatim: builtIn.joined(separator: "   ")))
                Spacer(minLength: 8)
                Button("Apply") { applyVisibilityDrafts() }
                    .buttonStyle(LitheActionButtonStyle())
            }
        }
    }

    private func autoSaveDelayTitle(_ delay: Double) -> String {
        switch delay {
        case 0.5: "0.5 seconds"
        case 1.5: "1.5 seconds"
        default: "3 seconds"
        }
    }

    private var editorSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Display") {
                row("Font") {
                    VStack(alignment: .leading, spacing: 4) {
                        LitheSettingsSelect(
                            selection: $settings.editorFontFamily,
                            options: editorFontOptions,
                            width: 240,
                            accessibilityLabel: "Font",
                            title: { $0 },
                            localizesTitles: false,
                            isAvailable: { MacEditorFontCatalog.isAvailable(family: $0) },
                            searchPrompt: "Search fonts",
                            searchText: { $0 }
                        )
                        if let coverageNotice = editorFontCoverageNotice {
                            Text(coverageNotice)
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 420, alignment: .leading)
                        }
                    }
                }
                fontPreview
                row("Font size") {
                    LitheSettingsStepper(
                        value: $settings.editorFontSize,
                        in: 8...22,
                        step: 1,
                        width: 126,
                        accessibilityLabel: "Font size",
                        title: { "\(Int($0)) pt" }
                    )
                }
                row("File tree row height") {
                    LitheSettingsStepper(
                        value: $settings.projectTreeRowHeight,
                        in: 20...32,
                        step: 1,
                        width: 126,
                        accessibilityLabel: "File tree row height",
                        title: { "\(Int($0)) pt" }
                    )
                }
                LitheSettingsCheckbox(
                    isOn: $settings.showCodeVision,
                    title: "Show usages and Git author"
                )
                LitheSettingsCheckbox(
                    isOn: $settings.editorMinimapEnabled,
                    title: "Show minimap"
                )
            }
            group("Editor tabs") {
                row("Layout") {
                    LitheSettingsSelect(
                        selection: $settings.editorTabLayoutMode,
                        options: EditorTabLayoutMode.allCases,
                        width: 180,
                        accessibilityLabel: "Layout",
                        title: \EditorTabLayoutMode.title
                    )
                }
            }
            group("Indentation") {
                row("Tab width") {
                    LitheSettingsSelect(
                        selection: $settings.tabWidth,
                        options: [2, 4, 8],
                        width: 130,
                        accessibilityLabel: "Tab width",
                        title: { "\($0) spaces" }
                    )
                }
            }
        }
        .task {
            guard viewState.editorFontFamilies.isEmpty else { return }
            viewState.editorFontFamilies = MacEditorFontCatalog.editorFamilies()
        }
        .onAppear { lastEditorFontFamily = settings.editorFontFamily }
        .onChange(of: settings.editorFontFamily) { newValue in
            let previous = lastEditorFontFamily
            lastEditorFontFamily = newValue
            guard let previous, previous != newValue else { return }

            fontPreviewResetTask?.cancel()
            withAnimation(fontPreviewAnimation) { previousEditorFontFamily = previous }
            fontPreviewResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(fontPreviewAnimation) { previousEditorFontFamily = nil }
            }
        }
        .onDisappear {
            fontPreviewResetTask?.cancel()
            previousEditorFontFamily = nil
        }
    }

    private var fontPreviewAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    /// Live sample in the selected face. After a change the previous face stays
    /// visible for a moment, so the user can compare the two renderings before
    /// the preview settles on the new one.
    private var fontPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let previousEditorFontFamily {
                fontPreviewLine(family: previousEditorFontFamily, isCurrent: false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            fontPreviewLine(family: settings.editorFontFamily, isCurrent: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .litheSettingsControlChrome(background: LitheTheme.settingsTextFieldBackground)
        .animation(fontPreviewAnimation, value: previousEditorFontFamily)
    }

    private func fontPreviewLine(family: String, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: MacEditorFontCatalog.resolvedFamily(family))
                .font(LitheTheme.uiFont(size: 10.5))
                .foregroundStyle(LitheTheme.tertiaryText)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(verbatim: "func greet(name: String) -> String { \"Hello, \\(name)!\" } // 0O Il1")
                .font(Font(MacEditorFontCatalog.font(family: family, size: settings.editorFontSize)))
                .foregroundStyle(isCurrent ? LitheTheme.primaryText : LitheTheme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    /// Monospaced families plus the stored selection. The stored family is kept
    /// in the list even when it is no longer installed, so the user can see what
    /// is configured instead of the control silently snapping to the default.
    private var editorFontOptions: [String] {
        var options = viewState.editorFontFamilies
        if options.isEmpty { options = [settings.editorFontFamily] }
        if !options.contains(settings.editorFontFamily) { options.append(settings.editorFontFamily) }
        return options
    }

    /// Warns when the chosen family cannot render character groups the product
    /// needs, because those glyphs then come from the fallback chain instead of
    /// the font the user picked.
    ///
    /// The bundled default is deliberately exempt: it is the baseline and the
    /// fallback target itself, so warning about the shipped font would be noise
    /// the user cannot act on. An uninstalled family is reported by the control's
    /// own unavailable styling rather than twice.
    private var editorFontCoverageNotice: String? {
        let family = settings.editorFontFamily
        guard !EditorFontResolution.usesBundledMonospacedFamily(family),
              MacEditorFontCatalog.isAvailable(family: family) else { return nil }

        let coverage = MacEditorFontCatalog.coverage(
            family: family,
            requirements: .forLanguage(settings.language)
        )
        guard let description = coverage.missingDescription else { return nil }

        return String(
            format: String(
                localized: "%@ does not include %@; Lithe renders those characters with %@ and the system font."
            ),
            coverage.family,
            description,
            EditorFontDefaults.monospacedFamily
        )
    }

    private var terminalSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Shell") {
                row("Default shell", info: "Used for new terminal sessions.") {
                    LitheSettingsSelect(
                        selection: Binding(
                            get: { settings.terminalShellPath ?? "" },
                            set: { path in
                                guard path.isEmpty || terminalShellIsAvailable(path) else {
                                    missingTerminalShellPath = path
                                    return
                                }
                                settings.selectTerminalShell(path: path)
                            }
                        ),
                        options: terminalShellOptions,
                        width: 320,
                        accessibilityLabel: "Default shell",
                        title: terminalShellTitle,
                        isAvailable: terminalShellIsAvailable,
                        onUnavailableSelection: { path in missingTerminalShellPath = path }
                    )
                }
                Button("Detect Installed Shells") {
                    model.terminalFeature?.refreshAvailableShells()
                    viewState.detectedTerminalShells = model.availableTerminalShells
                    viewState.knownTerminalShells = MacTerminalShellDiscovery.knownShells()
                }
                .buttonStyle(LitheActionButtonStyle())
            }
            group("Scrollback") {
                row("Terminal scrollback", info: "Lines kept for scrolling back in new terminal sessions.") {
                    LitheSettingsStepper(
                        value: $settings.terminalScrollbackLines,
                        in: AppSettings.terminalScrollbackLinesRange,
                        step: 500,
                        width: 146,
                        accessibilityLabel: "Terminal scrollback",
                        title: { settings.language.localizedFormat("%lld lines", $0) }
                    )
                }
            }
        }
        .task {
            guard await model.activateTerminalModule() else { return }
            viewState.detectedTerminalShells = model.availableTerminalShells
            viewState.knownTerminalShells = MacTerminalShellDiscovery.knownShells()
        }
    }

    private var terminalShellOptions: [String] {
        var options = [""] + viewState.knownTerminalShells
        options += viewState.detectedTerminalShells.filter { !options.contains($0) }
        if let selected = settings.terminalShellPath, !options.contains(selected) { options.append(selected) }
        return options
    }

    private func terminalShellIsAvailable(_ path: String) -> Bool {
        if path.isEmpty { return detectedSystemShellPath != nil }
        return viewState.detectedTerminalShells.contains(path)
    }

    private func terminalShellTitle(_ path: String) -> String {
        if path.isEmpty {
            guard let detectedSystemShellPath else {
                return settings.language.localizedString("System default · Shell not detected")
            }
            return settings.language.localizedFormat(
                "System default · %@ (%@)",
                terminalShellName(detectedSystemShellPath),
                detectedSystemShellPath
            )
        }
        return "\(terminalShellName(path)) (\(path))"
    }

    private var detectedSystemShellPath: String? {
        if let environmentShell = ProcessInfo.processInfo.environment["SHELL"],
           viewState.detectedTerminalShells.contains(environmentShell) {
            return environmentShell
        }
        return viewState.detectedTerminalShells.first
    }

    private func terminalShellName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private var providersSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            LitheSettingsSection(title: "AI providers", accessory: {
                if !editingProviderIsConfigurationManaged {
                    LitheInfoTip("API keys are stored in Lithe's local application data and are never written to Lithe settings.")
                }
            }) {
                if settings.commitMessageAI.providers.isEmpty {
                    Text("No AI provider is configured yet.")
                        .foregroundStyle(LitheTheme.secondaryText)
                } else {
                    row("Provider") {
                        LitheSettingsSelect(
                            selection: Binding(
                                get: { editingProvider?.id ?? settings.commitMessageAI.providers[0].id },
                                set: { viewState.editingProviderID = $0 }
                            ),
                            options: settings.commitMessageAI.providers.map(\.id),
                            width: 240,
                            accessibilityLabel: "Provider",
                            title: providerTitle
                        )
                    }
                    if let editingProvider {
                        Text(providerUsage(editingProvider))
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                    }

                }

                HStack(spacing: LitheTheme.ActionButton.spacing) {
                    Button("Add Provider") {
                        viewState.editingProviderID = settings.addAIProvider()
                        syncAIProviderDraft()
                    }
                    .buttonStyle(LitheActionButtonStyle())

                    Button("Remove") {
                        if let id = editingProvider?.id { settings.removeAIProvider(id) }
                        viewState.editingProviderID = nil
                        syncAIProviderDraft()
                    }
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(editingProvider == nil)
                }

                if editingProvider != nil {
                    LitheTextField("Provider name", text: editingProviderTextBinding(\.name))
                        .disabled(editingProviderIsConfigurationManaged)
                    row("API protocol") {
                        LitheSettingsSelect(
                            selection: editingProviderProtocolBinding(),
                            options: CommitMessageAPIProtocol.allCases,
                            width: 240,
                            accessibilityLabel: "API protocol",
                            title: \CommitMessageAPIProtocol.title
                        )
                        .disabled(editingProviderIsConfigurationManaged)
                    }
                    LitheTextField("API URL", text: editingProviderTextBinding(\.endpoint))
                        .disabled(editingProviderIsConfigurationManaged)
                    if editingProvider?.usesInsecureHTTP == true {
                        LitheSettingsCheckbox(
                            isOn: editingProviderBoolBinding(\.allowsInsecureHTTP),
                            title: "Allow insecure HTTP"
                        )
                        .disabled(editingProviderIsConfigurationManaged)
                        Label(
                            editingProvider?.allowsInsecureHTTP == true
                                ? "HTTP sends the API credential without encryption. Use only a trusted endpoint."
                                : "HTTP is blocked until you explicitly allow it for this provider.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.warning)
                    }
                    LitheTextField("Model", text: editingProviderTextBinding(\.model))
                        .disabled(editingProviderIsConfigurationManaged)

                    HStack(spacing: 8) {
                        LitheTextField("API key or token", text: $viewState.aiAPIKeyDraft, secure: true)
                            .disabled(editingProviderIsConfigurationManaged)
                        Button("Save Key") {
                            if let editingProvider { model.saveAPIKey(viewState.aiAPIKeyDraft, for: editingProvider) }
                        }
                        .buttonStyle(LitheActionButtonStyle())
                        .disabled(editingProviderIsConfigurationManaged)
                    }

                    LitheSettingsCheckbox(
                        isOn: editingProviderBoolBinding(\.requiresAPIKey),
                        title: "Provider requires an API key"
                    )
                        .disabled(editingProviderIsConfigurationManaged)

                    if editingProviderIsConfigurationManaged,
                       let description = editingProvider.flatMap(model.configurationSourceDescription(for:)) {
                        Text(LocalizedStringKey(description))
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                    }
                }

                if !model.detectedAIConfigurations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.detectedAIConfigurations) { configuration in
                            HStack(alignment: .top, spacing: 8) {
                                LitheBannerIcon(status: .success)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(LocalizedStringKey(configuration.source.detectedTitle))
                                        .font(LitheTheme.uiFont(size: 12, weight: .medium))
                                    Text("\(configuration.model) · \(configuration.endpoint)")
                                        .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                                        .foregroundStyle(LitheTheme.secondaryText)
                                        .lineLimit(2)
                                    Text(LocalizedStringKey(
                                        configuration.hasCredential
                                            ? configuration.source.credentialAvailableTitle
                                            : configuration.source.noCredentialTitle
                                    ))
                                    .font(LitheTheme.smallFont)
                                    .foregroundStyle(LitheTheme.secondaryText)
                                }
                                Spacer()
                                Button(LocalizedStringKey(configuration.source.importTitle)) {
                                    if model.importAIConfiguration(configuration) {
                                        syncAIProviderDraft()
                                    }
                                }
                                .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                            }
                            .padding(10)
                            .background(LitheTheme.inputBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }

                        HStack {
                            Spacer()
                            Button {
                                reloadAIConfigurations()
                            } label: {
                                Label("Reload AI configurations", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(LitheActionButtonStyle())
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Lithe looks for Codex and Claude configuration files on this Mac.")
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                        Button {
                            reloadAIConfigurations()
                        } label: {
                            Label("Reload AI configurations", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(LitheActionButtonStyle())
                    }
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Provider being edited, falling back to the commit message provider.
    private var editingProvider: AIProviderProfile? {
        let providers = settings.commitMessageAI.providers
        return providers.first { $0.id == viewState.editingProviderID }
            ?? settings.activeCommitMessageProvider
            ?? providers.first
    }

    private var editingProviderIsConfigurationManaged: Bool {
        editingProvider.map(model.credentialIsConfigurationManaged(_:)) ?? false
    }

    /// Which features use `provider`, e.g. "Used by: commit messages, Codex".
    private func providerUsage(_ provider: AIProviderProfile) -> String {
        var users: [String] = []
        if settings.commitMessageAI.activeProviderID == provider.id { users.append(settings.language.localizedString("commit messages")) }
        users += settings.agentConfigurations.values
            .filter { $0.providerID == provider.id }
            .map(\.name)
            .sorted()
        return users.isEmpty
            ? settings.language.localizedString("Not used yet.")
            : settings.language.localizedFormat("Used by: %@", users.joined(separator: ", "))
    }

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Provider") {
                if settings.commitMessageAI.providers.isEmpty {
                    Text("Add an AI provider in AI Providers first.")
                        .foregroundStyle(LitheTheme.secondaryText)
                } else {
                    row("Commit messages use") {
                        LitheSettingsSelect(
                            selection: Binding(
                                get: { settings.commitMessageAI.activeProviderID ?? settings.commitMessageAI.providers[0].id },
                                set: { settings.selectCommitMessageProvider($0) }
                            ),
                            options: settings.commitMessageAI.providers.map(\.id),
                            width: 240,
                            accessibilityLabel: "Commit message provider",
                            title: providerTitle
                        )
                    }
                }
                Button("Manage AI Providers…") { viewState.selection = .providers }
                    .buttonStyle(LitheActionButtonStyle())
            }

            group("Commit message generation", info: "Low effort and a small output limit are recommended for fast commit-message generation.") {
                row("Reasoning effort") {
                    LitheSettingsSelect(
                        selection: $settings.commitMessageAI.reasoningEffort,
                        options: CommitMessageReasoningEffort.allCases,
                        width: 230,
                        accessibilityLabel: "Reasoning effort",
                        title: \CommitMessageReasoningEffort.title
                    )
                }

                row("Output language") {
                    LitheSettingsSelect(
                        selection: $settings.commitMessageAI.language,
                        options: CommitMessageLanguage.allCases,
                        width: 230,
                        accessibilityLabel: "Output language",
                        title: \CommitMessageLanguage.title
                    )
                }

                formatPicker

                LitheSettingsCheckbox(
                    isOn: $settings.commitMessageAI.includeBody,
                    title: "Include a short body when useful"
                )

                row("Subject maximum length") {
                    LitheSettingsStepper(
                        value: $settings.commitMessageAI.subjectMaximumLength,
                        in: 40...120,
                        step: 4,
                        width: 146,
                        accessibilityLabel: "Subject maximum length",
                        title: { "\($0) chars" }
                    )
                }

                row("Diff character limit") {
                    LitheSettingsStepper(
                        value: $settings.commitMessageAI.maximumDiffCharacters,
                        in: 8_000...120_000,
                        step: 4_000,
                        width: 146,
                        accessibilityLabel: "Diff character limit",
                        title: { "\($0)" }
                    )
                }

                if settings.commitMessageAI.format == .custom {
                    Text("Custom instructions")
                        .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                    LitheTextEditor(text: $settings.commitMessageAI.customInstructions, height: 92)
                }
            }

            group("Pull request description generation", info: "Pull request generation uses the selected provider, language, reasoning effort, and diff limit above.") {
                row("Description format") {
                    LitheSettingsSelect(
                        selection: $settings.commitMessageAI.pullRequestFormat,
                        options: PullRequestDescriptionFormat.allCases,
                        width: 220,
                        accessibilityLabel: "Description format",
                        title: \PullRequestDescriptionFormat.title
                    )
                }

                if settings.commitMessageAI.pullRequestFormat == .custom {
                    HStack(spacing: 4) {
                        Text("Markdown template")
                            .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                        LitheInfoTip("Supported placeholders: {summary}, {changes}, {testing}, {risks}.")
                        Spacer()
                        Button("Restore Default Template") {
                            settings.commitMessageAI.pullRequestCustomTemplate =
                                CommitMessageAISettings.defaultPullRequestTemplate
                        }
                        .buttonStyle(LitheActionButtonStyle())
                        .lithePointer()
                    }

                    LitheTextEditor(text: $settings.commitMessageAI.pullRequestCustomTemplate, height: 150)
                }

                Label(
                    "The selected branch diff is sent to the active AI provider when you generate.",
                    systemImage: "lock.shield"
                )
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    private var formatPicker: some View {
        HStack(alignment: .top, spacing: 12) {
            LitheSettingsLabel("Format")
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 16)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    toggleFormatPicker()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: settings.commitMessageAI.format.icon)
                            .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                            .foregroundStyle(LitheTheme.accent)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(settings.commitMessageAI.format.title))
                                .font(LitheTheme.uiFont(size: 12.5, weight: .medium))
                                .foregroundStyle(LitheTheme.primaryText)
                            Text(LocalizedStringKey(settings.commitMessageAI.format.description))
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.down")
                            .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                            .foregroundStyle(LitheTheme.secondaryText)
                            .rotationEffect(.degrees(viewState.isFormatPickerPresented ? 180 : 0))
                            .animation(formatPickerAnimation, value: viewState.isFormatPickerPresented)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .litheSettingsControlChrome(
                        background: LitheTheme.settingsTextFieldBackground,
                        border: viewState.isFormatPickerPresented ? LitheTheme.settingsControlAccent : LitheTheme.settingsControlBorder
                    )
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .litheDropdown(isPresented: $viewState.isFormatPickerPresented) {
                    formatPickerPopover
                }

                formatExample
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var formatPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Choose a commit format")
                        .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    LitheInfoTip("Each built-in preset includes a preview of the generated message.")
                }

                Spacer(minLength: 8)

                Button {
                    viewState.isFormatPickerPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(LitheTheme.uiFont(size: 10, weight: .semibold))
                }
                .litheIconButton()
                .help("Close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle()
                .fill(LitheTheme.divider)
                .frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(CommitMessageFormat.builtInCases) { format in
                        formatOption(format)
                    }

                    Rectangle()
                        .fill(LitheTheme.divider)
                        .frame(height: 1)
                        .padding(.vertical, 4)

                    formatOption(.custom)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 430)
        .lithePopupChrome(cornerRadius: 8)
    }

    private func formatOption(_ format: CommitMessageFormat) -> some View {
        let isSelected = settings.commitMessageAI.format == format

        return Button {
            selectFormat(format)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: format.icon)
                    .font(LitheTheme.uiFont(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? LitheTheme.accent : LitheTheme.secondaryText)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(format.title))
                            .font(LitheTheme.uiFont(size: 12, weight: .medium))
                            .foregroundStyle(LitheTheme.primaryText)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(LitheTheme.uiFont(size: 10, weight: .bold))
                                .foregroundStyle(LitheTheme.accent)
                        }
                    }

                    Text(LocalizedStringKey(format.description))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)

                    if format != .custom {
                        Text(LocalizedStringKey(format.example))
                            .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(format == .descriptive ? 3 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(.litheNoPress)
        .litheRowHover(
            isActive: isSelected,
            cornerRadius: 5,
            activeBackground: LitheTheme.subtleSelection
        )
        .lithePointer()
    }

    @ViewBuilder
    private var formatExample: some View {
        if settings.commitMessageAI.format != .custom {
            VStack(alignment: .leading, spacing: 5) {
                Text("Example")
                    .font(LitheTheme.uiFont(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)

                Text(LocalizedStringKey(settings.commitMessageAI.format.example))
                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                    .foregroundStyle(LitheTheme.primaryText)
                    .lineLimit(settings.commitMessageAI.format == .descriptive ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .litheSettingsControlChrome(background: LitheTheme.settingsTextFieldBackground)
                    .id(settings.commitMessageAI.format)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(formatPickerAnimation, value: settings.commitMessageAI.format)
            }
        }
    }

    private var formatPickerAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    private func toggleFormatPicker() {
        withAnimation(formatPickerAnimation) {
            viewState.isFormatPickerPresented.toggle()
        }
    }

    private func selectFormat(_ format: CommitMessageFormat) {
        withAnimation(formatPickerAnimation) {
            settings.commitMessageAI.format = format
            viewState.isFormatPickerPresented = false
        }
    }

    private var updatesSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("Application version", info: "Lithe checks GitHub Releases for published updates.") {
                row("Current version") {
                    Text(updateChecker.versionDescription)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .monospacedDigit()
                }
            }

            group("Update channel") {
                UpdateChannelControl()
            }

            group("Update status") {
                updateStatusDescription
                StableRollbackControl()

                HStack(spacing: LitheTheme.ActionButton.spacing) {
                    // An update found here is installed from the button beside
                    // this one, so the check does not open the update window.
                    let checkButton = Button {
                        Task { await updateChecker.checkForUpdates(manual: true) }
                    } label: {
                        Label(
                            updateChecker.isChecking ? "Checking for updates…" : "Check for Updates",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(updateChecker.isBusy)
                    if case .available = updateChecker.status {
                        checkButton.buttonStyle(LitheActionButtonStyle())
                    } else {
                        checkButton.buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    }

                    if case .waitingForTermination = updateChecker.status {
                        Button {
                            Task { await updateChecker.retryInstallation() }
                        } label: {
                            Label("Continue Installation", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(LitheActionButtonStyle())
                    }
                    if case .available(let version, _) = updateChecker.status {
                        Button {
                            Task { await updateChecker.installAvailableUpdate() }
                        } label: {
                            if updateChecker.isPreview {
                                Label("Install AutoBuild", systemImage: "arrow.down.circle.fill")
                            } else {
                                Label("Update \(version)", systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                        .disabled(updateChecker.isBusy)
                    }
                }
            }
        }
    }

    private var diagnosticsSettings: some View {
        ApplicationLogDiagnosticsPage(feature: model.diagnosticsFeature) {
            logDirectoryControls
        }
    }

    private var logDirectoryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Log directory")
                .font(LitheTheme.uiFont(size: 11.5, weight: .medium))

            HStack(spacing: 10) {
                Text(settings.logDirectory.path)
                    .font(LitheTheme.uiFont(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(settings.logDirectory.path)

                Spacer(minLength: 8)

                Button {
                    guard let directory = model.platformUI.chooseDirectory(
                        title: "Choose Log Directory",
                        prompt: "Choose"
                    ) else { return }
                    Task {
                        if await model.diagnosticsFeature.changeLogDirectory(to: directory) {
                            settings.setCustomLogDirectory(directory)
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(LitheTheme.uiFont(size: 16, weight: .regular))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.litheNoPress)
                .foregroundStyle(LitheTheme.secondaryText)
                .contentShape(Rectangle())
                .lithePointer()
                .help("Choose Directory")
                .disabled(model.diagnosticsFeature.isBusy)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
            .litheSettingsControlChrome(background: LitheTheme.settingsTextFieldBackground)

            HStack(spacing: 6) {
                Text("Default directory")
                    .foregroundStyle(LitheTheme.secondaryText)
                Text(settings.defaultLogDirectory.path)
                    .foregroundStyle(LitheTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(settings.defaultLogDirectory.path)

                Spacer(minLength: 8)

                if settings.customLogDirectory != nil {
                    Button {
                        Task {
                            if await model.diagnosticsFeature.changeLogDirectory(to: settings.defaultLogDirectory) {
                                settings.setCustomLogDirectory(nil)
                            }
                        }
                    } label: {
                        Text("Restore Default")
                    }
                    .buttonStyle(.litheNoPress)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
                    .disabled(model.diagnosticsFeature.isBusy)
                }
            }
            .font(LitheTheme.smallFont)
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Button("Open Log Directory") { model.platformUI.open(settings.logDirectory) }
                Button("Copy Path") { model.platformUI.copyToClipboard(settings.logDirectory.path) }
            }
            .buttonStyle(LitheActionButtonStyle())
        }
    }

    @ViewBuilder
    private var updateStatusDescription: some View {
        switch updateChecker.status {
        case .idle:
            Text("No update check has been performed yet.")
                .foregroundStyle(LitheTheme.secondaryText)
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking GitHub Releases…")
            }
            .foregroundStyle(LitheTheme.secondaryText)
        case .available(let version, _):
            Label("Version \(version) is available.", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(LitheTheme.accent)
        case .downloading(let version, let progress):
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if let fractionCompleted = progress.fractionCompleted {
                        ProgressView(value: fractionCompleted)
                            .frame(maxWidth: .infinity)
                        Text("\(progress.percentage ?? 0)%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                        Text("Preparing…")
                            .frame(width: 58, alignment: .trailing)
                    }
                }
                Text("Downloading update \(version)…")
                    .font(LitheTheme.smallFont)
                if progress.downloadedBytes > 0 {
                    Text(progress.byteCountDescription)
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
            }
            .foregroundStyle(LitheTheme.secondaryText)
        case .waitingForTermination:
            Text("Waiting to quit to complete the update.")
                .foregroundStyle(LitheTheme.secondaryText)
        case .installing(let version):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing update \(version)…")
            }
            .foregroundStyle(LitheTheme.secondaryText)
        case .upToDate(let version):
            Label("Lithe is up to date at version \(version).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(LitheTheme.success)
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<Content: View>(
        _ title: String,
        info: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LitheSettingsSection(title: title, accessory: {
            if let info {
                LitheInfoTip(info)
            }
        }, content: content)
    }

    private func row<Content: View>(
        _ title: String,
        info: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LitheSettingsRow(LocalizedStringKey(title), info: info) {
            content()
        }
    }

    private func syncAIProviderDraft() {
        viewState.aiAPIKeyDraft = editingProvider.map(model.apiKey(for:)) ?? ""
    }

    private func providerTitle(_ id: UUID) -> String {
        guard let provider = settings.commitMessageAI.providers.first(where: { $0.id == id }) else {
            return "Unnamed provider"
        }
        return provider.name.isEmpty ? "Unnamed provider" : provider.name
    }

    private func reloadAIConfigurations() {
        model.refreshAIConfigurations()
        syncAIProviderDraft()
    }

    private func editingProviderTextBinding(
        _ keyPath: WritableKeyPath<AIProviderProfile, String>
    ) -> Binding<String> {
        Binding(
            get: { editingProvider?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let id = editingProvider?.id else { return }
                settings.updateAIProvider(id) { provider in provider[keyPath: keyPath] = value }
            }
        )
    }

    private func editingProviderProtocolBinding() -> Binding<CommitMessageAPIProtocol> {
        Binding(
            get: { editingProvider?.apiProtocol ?? .responses },
            set: { value in
                guard let id = editingProvider?.id else { return }
                settings.updateAIProvider(id) { provider in provider.apiProtocol = value }
            }
        )
    }

    private func editingProviderBoolBinding(
        _ keyPath: WritableKeyPath<AIProviderProfile, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { editingProvider?[keyPath: keyPath] ?? true },
            set: { value in
                guard let id = editingProvider?.id else { return }
                settings.updateAIProvider(id) { provider in provider[keyPath: keyPath] = value }
            }
        )
    }

    private var footer: some View {
        HStack {
            Button("Restore Defaults") { settings.restoreDefaults() }
                .buttonStyle(LitheActionButtonStyle())
            Spacer()
            HStack(spacing: LitheTheme.ActionButton.spacing) {
                Button { closeSettings() } label: {
                    Text("Cancel")
                }
                    .buttonStyle(LitheActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(viewState.isApplyingPluginChanges)
                Button {
                    Task { @MainActor in
                        if await viewState.applyPluginChanges(model.applyPluginEnabledChanges) {
                            closeSettings()
                        }
                    }
                } label: {
                    Text("OK")
                }
                    .buttonStyle(LitheActionButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewState.isApplyingPluginChanges)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(LitheTheme.settingsCard)
    }

    private func syncVisibilityDrafts() {
        viewState.hiddenPathPatternsDraft = settings.hiddenPathPatterns.joined(separator: "\n")
    }

    private func applyVisibilityDrafts() {
        settings.hiddenPathPatterns = entries(from: viewState.hiddenPathPatternsDraft)
    }

    private func entries(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func closeSettings() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

/// The colored tile in front of a top-level sidebar row, like the icons in
/// macOS System Settings. Every group has one; plugin pages nest under them.
private struct SettingsSidebarIcon: View {
    enum Style {
        case group(SettingsGroup)
        case page(SettingsCategory)
    }

    let style: Style

    var body: some View {
        let (symbol, color) = appearance
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color)
            .frame(width: 20, height: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var appearance: (String, Color) {
        switch style {
        case .group(.appearance): ("circle.lefthalf.filled", Color(red: 0.37, green: 0.36, blue: 0.90))
        case .group(.versionControl): ("arrow.triangle.branch", Color(red: 0.94, green: 0.32, blue: 0.20))
        case .group(.build): ("play.fill", Color(red: 0.20, green: 0.66, blue: 0.33))
        case .group(.languages): ("curlybraces", Color(red: 0.04, green: 0.52, blue: 1.0))
        case .group(.tools): ("wrench.and.screwdriver.fill", Color(red: 0.56, green: 0.56, blue: 0.58))
        case .group(.ai): ("sparkles", Color(red: 0.75, green: 0.35, blue: 0.95))
        case .page: ("puzzlepiece.extension.fill", Color(red: 1.0, green: 0.62, blue: 0.04))
        }
    }
}

/// The chosen workbench background as a small thumbnail with its name; a
/// click shows it larger. The image is decoded once per change into a
/// downsampled copy, so resizing the window never decodes the original.
/// Observes the background feature itself: the settings window does not
/// rebuild on relayed workbench feature changes.
private struct WorkbenchBackgroundImageError: View {
    @ObservedObject var feature: WorkbenchBackgroundFeatureModel

    var body: some View {
        if let error = feature.imageError {
            Label {
                Text(LocalizedStringKey(error))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(LitheTheme.smallFont)
            .foregroundStyle(LitheTheme.warning)
            .fixedSize(horizontal: false, vertical: true)

            Button("Retry") {
                feature.retry()
            }
            .buttonStyle(.litheNoPress)
            .foregroundStyle(LitheTheme.accent)
            .lithePointer()
        }
    }
}

/// The chosen file name, or the placeholder. A `Text` literal follows the app
/// language through the environment locale; `L10n.string` follows the application language.
func workbenchBackgroundNameText(_ name: String?) -> Text {
    name.map { Text(verbatim: $0) } ?? Text("No background image selected")
}

private struct WorkbenchBackgroundThumbnail: View {
    @ObservedObject var feature: WorkbenchBackgroundFeatureModel
    @State private var thumbnail: NSImage?
    @State private var preview: NSImage?
    @State private var showsPreview = false

    var body: some View {
        HStack(spacing: 8) {
            Button { if thumbnail != nil { showsPreview = true } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(LitheTheme.settingsPill)
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .font(LitheTheme.uiFont(size: 13))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(LitheTheme.settingsCardRing, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .disabled(thumbnail == nil)
            .help(Text("Preview background image"))
            .accessibilityLabel(Text("Preview background image"))
            .litheDropdown(isPresented: $showsPreview) {
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 480, maxHeight: 320)
                        .padding(8)
                }
            }

            workbenchBackgroundNameText(feature.displayName)
                .foregroundStyle(LitheTheme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .task(id: feature.imageData) {
            guard let data = feature.imageData else {
                thumbnail = nil
                preview = nil
                return
            }
            let images = await Task.detached(priority: .utility) {
                (Self.downsample(data, maxPixel: 160), Self.downsample(data, maxPixel: 960))
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = images.0.map { NSImage(cgImage: $0, size: .zero) }
            preview = images.1.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}
