import SwiftUI
import LitheCoreContracts
import LitheGitModule
import LitheModuleAPI

@MainActor
final class SettingsViewState: ObservableObject {
    @Published var selection: SettingsCategory
    @Published var searchQuery = ""
    @Published var hiddenDirectoriesDraft = ""
    @Published var hiddenFilePatternsDraft = ""
    @Published var aiAPIKeyDraft = ""
    /// Provider shown in Settings › AI Providers; independent of the one
    /// commit messages use.
    @Published var editingProviderID: UUID?
    @Published var isFormatPickerPresented = false
    @Published var detectedTerminalShells: [String] = []
    @Published var knownTerminalShells: [String] = []
    @Published var pendingPluginEnabledStates: [PluginID: Bool] = [:]
    @Published private(set) var isApplyingPluginChanges = false

    init(initialCategory: SettingsCategory) {
        selection = initialCategory
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
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewState: SettingsViewState
    @AppStorage("lithe.settings.categorySidebarWidth") private var categorySidebarWidth = 234.0
    @State private var missingTerminalShellPath: String?
    @State private var expandedSidebarGroups: Set<String> = []
    let initialCategory: SettingsCategory
    /// Changes with every category request; see `WorkbenchFeatureModel.settingsCategoryRequest`.
    let categoryRequest: Int
    private let onDismiss: (() -> Void)?
    static let categoryMinimumWidth: CGFloat = 234
    static let contentMinimumWidth: CGFloat = 500
    private static let footerActionLabelWidth: CGFloat = 52

    init(
        settings: AppSettings,
        viewState: SettingsViewState,
        initialCategory: SettingsCategory = .general,
        categoryRequest: Int = 0,
        onDismiss: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.viewState = viewState
        self.initialCategory = initialCategory
        self.categoryRequest = categoryRequest
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                LitheSplitPaneView(
                    axis: .horizontal,
                    placement: .leading,
                    defaultSize: CGFloat(categorySidebarWidth),
                    minimum: Self.categoryMinimumWidth,
                    maximum: max(Self.categoryMinimumWidth, geometry.size.width - SplitHandleView.thickness - Self.contentMinimumWidth),
                    flexibleMinimum: Self.contentMinimumWidth,
                    highlightsOnHover: false,
                    onCommit: { categorySidebarWidth = Double($0) },
                    sized: { categories },
                    flexible: {
                        content.simultaneousGesture(TapGesture().onEnded { isSearchFocused = false })
                    }
                )
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(minWidth: 900, minHeight: 668)
        .background {
            LitheTheme.settingsSurface
                .ignoresSafeArea()
        }
        .onAppear {
            expandGroup(containing: viewState.selection)
            syncVisibilityDrafts()
            model.refreshAIConfigurations()
            syncAIProviderDraft()
        }
        .onChange(of: settings.hiddenDirectoryNames) { _ in syncVisibilityDrafts() }
        .onChange(of: settings.hiddenFilePatterns) { _ in syncVisibilityDrafts() }
        .onChange(of: settings.commitMessageAI.activeProviderID) { _ in syncAIProviderDraft() }
        .onChange(of: viewState.editingProviderID) { _ in syncAIProviderDraft() }
        .onChange(of: initialCategory) { category in
            viewState.searchQuery = ""
            viewState.selection = category
        }
        .onChange(of: categoryRequest) { _ in
            viewState.searchQuery = ""
            viewState.selection = initialCategory
            expandGroup(containing: initialCategory)
        }
        .onChange(of: viewState.selection) { category in
            expandGroup(containing: category)
        }
        .onChange(of: viewState.searchQuery) { _ in
            guard !filteredCategories.contains(viewState.selection),
                  let firstMatch = filteredCategories.first else { return }
            viewState.selection = firstMatch
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
                .padding(.horizontal, 8)
                .padding(.top, 11)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 0) {
                    categoryGroup("Appearance & Behavior", categories: [.general, .updates])
                    categoryButton(.keymap)
                    categoryButton(.editor)
                    categoryButton(.plugins)
                    categoryGroup("Version Control", categories: [.git])
                    categoryGroup("Build, Execution, Deployment", categories: [.project, .run])
                    categoryGroup("Languages & Frameworks", categories: [.lsp])
                    categoryGroup("Tools", categories: [.terminal, .ai, .providers, .diagnostics])

                    if filteredCategories.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 18, weight: .light))
                            Text("No settings found")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 28)
                    }
                }
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .background(LitheTheme.settingsSurface)
    }

    private var settingsSearchField: some View {
        LitheSettingsSearchField("", text: $viewState.searchQuery, focus: $isSearchFocused)
            .accessibilityLabel("Search settings")
    }

    @ViewBuilder
    private func categoryGroup(_ title: String, categories: [SettingsCategory]) -> some View {
        let visible = categories.filter { filteredCategories.contains($0) }
        if !visible.isEmpty {
            let expanded = expandedSidebarGroups.contains(title) || !viewState.searchQuery.isEmpty
            Button {
                isSearchFocused = false
                if expandedSidebarGroups.contains(title) {
                    expandedSidebarGroups.remove(title)
                } else {
                    expandedSidebarGroups.insert(title)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 10)
                    Text(LocalizedStringKey(title))
                        .font(LitheTheme.settingsStrongFont)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .foregroundStyle(LitheTheme.primaryText)
            if expanded {
                ForEach(visible) { category in
                    categoryButton(category, nested: true)
                }
            }
        }
    }

    @ViewBuilder
    private func categoryButton(_ category: SettingsCategory, nested: Bool = false) -> some View {
        if filteredCategories.contains(category) {
            let isSelected = viewState.selection == category
            Button {
                isSearchFocused = false
                viewState.selection = category
            } label: {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 10)
                    Text(LocalizedStringKey(category.title))
                        .font(nested ? LitheTheme.settingsFont : LitheTheme.settingsStrongFont)
                    Spacer(minLength: 0)
                }
                .padding(.leading, nested ? 30 : 16)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .background(isSelected ? LitheTheme.settingsSelection : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.litheNoPress)
            .foregroundStyle(LitheTheme.primaryText)
        }
    }

    private func expandGroup(containing category: SettingsCategory) {
        switch category {
        case .general, .updates: expandedSidebarGroups.insert("Appearance & Behavior")
        case .git: expandedSidebarGroups.insert("Version Control")
        case .project, .run: expandedSidebarGroups.insert("Build, Execution, Deployment")
        case .lsp: expandedSidebarGroups.insert("Languages & Frameworks")
        case .terminal, .ai, .providers, .diagnostics: expandedSidebarGroups.insert("Tools")
        case .keymap, .editor, .plugins: break
        }
    }

    private var filteredCategories: [SettingsCategory] {
        let query = viewState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return SettingsCategory.allCases }

        return SettingsCategory.allCases.filter { category in
            searchTerms(for: category).contains { term in
                localizedSearchValue(term).localizedCaseInsensitiveContains(query)
                    || term.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private func searchTerms(for category: SettingsCategory) -> [String] {
        switch category {
        case .general:
            ["General", "Appearance", "Color theme", "Appearance mode", "Language", "Projects", "Files", "Version control", "Logs", "Log directory", "Hidden paths"]
        case .editor:
            ["Editor", "Display", "Editor tabs", "Font size", "File tree row height", "Show minimap", "Minimap", "Indentation", "Tab width"]
        case .keymap:
            ["Keymap", "Keyboard shortcuts", "Shortcuts", "Actions"]
        case .project:
            ["Project", "Java SDK", "JDK", "Project JDK", "Maven", "Maven Home", "Maven Wrapper", "Maven JDK"]
        case .run:
            ["Run configurations", "Program arguments", "VM options", "Environment variables", "Working directory", "Services"]
        case .terminal:
            ["Terminal", "Shell", "Default shell"]
        case .lsp:
            ["LSP", "Language server"]
        case .ai:
            ["AI & Commit", "Commit message", "Pull request"]
        case .providers:
            ["AI Providers", "AI provider", "Model", "API key", "Endpoint", "Responses", "Anthropic"]
        case .git:
            ["Git", "Fetch", "Tags", "Submodules", "Prune", "Commit identity", "Committer name", "Committer email", "Configuration scope", "user.name", "user.email"]
        case .updates:
            ["Updates", "Application version", "Update status", "Check for Updates"]
        case .diagnostics:
            ["Diagnostics", "Diagnostics bundle", "Export logs", "Bug report"]
        case .plugins:
            ["Plugins", "Installed", "Marketplace", "Language support"]
        }
    }

    private func localizedSearchValue(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            bundle: .main,
            locale: settings.language.locale
        )
    }

    private var content: some View {
        VStack(spacing: 0) {
            if viewState.selection != .plugins {
                HStack(spacing: 8) {
                    ForEach(Array(settingsBreadcrumb.enumerated()), id: \.offset) { index, title in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(LitheTheme.secondaryText)
                        }
                        Text(LocalizedStringKey(title))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(LitheTheme.primaryText)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
            }

            settingsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsBreadcrumb: [String] {
        switch viewState.selection {
        case .general: ["Appearance & Behavior", "General"]
        case .editor: ["Editor"]
        case .keymap: ["Keymap"]
        case .project: ["Build, Execution, Deployment", "Project · JDK & Maven"]
        case .run: ["Build, Execution, Deployment", "Run configurations"]
        case .terminal: ["Tools", "Terminal"]
        case .lsp: ["Languages & Frameworks", "LSP"]
        case .ai: ["Tools", "AI & Commit"]
        case .providers: ["Tools", "AI Providers"]
        case .git: ["Version Control", "Git"]
        case .updates: ["Appearance & Behavior", "Updates"]
        case .diagnostics: ["Tools", "Diagnostics"]
        case .plugins: ["Plugins"]
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if filteredCategories.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                Text("No settings found")
                    .font(.system(size: 15, weight: .medium))
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
                VStack(alignment: .leading, spacing: 12) {
                    switch viewState.selection {
                    case .general: generalSettings
                    case .editor: editorSettings
                    case .keymap: EmptyView()
                    case .terminal: terminalSettings
                    case .lsp: EmptyView()
                    case .project: EmptyView()
                    case .run: EmptyView()
                    case .ai: aiSettings
                    case .providers: providersSettings
                    case .git:
                        VStack(alignment: .leading, spacing: 14) {
                            GitExecutionSettingsView(settings: settings)
                            GitFetchSettingsView(options: $settings.gitFetchOptions)
                            GitIdentitySettingsView()
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                    case .updates: updatesSettings
                    case .diagnostics: diagnosticsSettings
                    case .plugins: EmptyView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Appearance") {
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

                Text("Choose a color theme and whether Lithe follows the system appearance.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)

                Divider().padding(.vertical, 2)

                Text("Workbench background")
                    .font(.system(size: 11.5, weight: .medium))

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.workbenchBackgroundFeature.displayName ?? "No background image selected")
                            .lineLimit(1)
                        Text("Shown across the entire workbench, including toolbars, project tree, editor, tabs, terminals, and status bar.")
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                    }

                    Spacer(minLength: 8)

                    Button("Choose Image…") {
                        model.workbenchBackgroundFeature.chooseCustomImage()
                    }
                    .buttonStyle(LitheSecondaryButtonStyle())

                    if settings.hasConfiguredWorkbenchBackground {
                        Button("Remove") {
                            model.workbenchBackgroundFeature.clear()
                        }
                        .buttonStyle(.litheNoPress)
                        .foregroundStyle(LitheTheme.accent)
                        .lithePointer()
                    }
                }

                if let error = model.workbenchBackgroundFeature.imageError {
                    Label {
                        Text(LocalizedStringKey(error))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)

                    Button("Retry") {
                        model.workbenchBackgroundFeature.retry()
                    }
                    .buttonStyle(.litheNoPress)
                    .foregroundStyle(LitheTheme.accent)
                    .lithePointer()
                }

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
                row("Language") {
                    LitheSettingsSelect(
                        selection: $settings.language,
                        options: AppLanguage.allCases,
                        width: 190,
                        accessibilityLabel: "Language",
                        title: \AppLanguage.title
                    )
                }

                Text("The interface language changes immediately. English is the default.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Projects") {
                row("Open projects in") {
                    LitheSettingsSelect(
                        selection: $settings.projectOpenBehavior,
                        options: ProjectOpenBehavior.allCases,
                        width: 190,
                        accessibilityLabel: "Open projects in",
                        title: \ProjectOpenBehavior.title
                    )
                }

                Text("Choose whether opening another project asks first, stays in this window, or creates a new window.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
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

            group("Git") {
                row("Save local changes with") {
                    LitheSettingsSelect(
                        selection: $settings.gitSaveChangesPolicy,
                        options: GitSaveChangesPolicy.allCases,
                        width: 180,
                        accessibilityLabel: "Save local changes with",
                        title: \GitSaveChangesPolicy.title
                    )
                }

                Text(LocalizedStringKey(settings.gitSaveChangesPolicy.description))
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            group("Hidden paths") {
                Text("One entry per line. Directory names hide matching folders; file entries support * and ?.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)

                Text("Directories")
                    .font(.system(size: 11.5, weight: .medium))
                TextEditor(text: $viewState.hiddenDirectoriesDraft)
                    .litheSettingsTextEditor(height: 66)

                Text("File patterns")
                    .font(.system(size: 11.5, weight: .medium))
                TextEditor(text: $viewState.hiddenFilePatternsDraft)
                    .litheSettingsTextEditor(height: 52)

                HStack(spacing: 8) {
                    Spacer()
                    Button("Apply") { applyVisibilityDrafts() }
                        .buttonStyle(LithePrimaryButtonStyle(
                            backgroundColor: LitheTheme.settingsPrimaryAction,
                            restingOpacity: 1
                        ))
                }
            }

            group("Logs") {
                Text("Log directory")
                    .font(.system(size: 11.5, weight: .medium))

                HStack(spacing: 10) {
                    Text(settings.logDirectory.path)
                        .font(.system(size: 13, weight: .medium))
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
                        settings.setCustomLogDirectory(directory)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 16, weight: .regular))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.litheNoPress)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .contentShape(Rectangle())
                    .lithePointer()
                    .help("Choose Directory")
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
                            settings.setCustomLogDirectory(nil)
                        } label: {
                            Text("Restore Default")
                        }
                        .buttonStyle(.litheNoPress)
                        .foregroundStyle(LitheTheme.accent)
                        .lithePointer()
                    }
                }
                .font(LitheTheme.smallFont)
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
        VStack(alignment: .leading, spacing: 18) {
            group("Display") {
                row("Font size") {
                    LitheSettingsStepper(
                        value: $settings.editorFontSize,
                        in: 10...22,
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
    }

    private var terminalSettings: some View {
        group("Shell") {
            row("Default shell") {
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
            Text("Used for new terminal sessions.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
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
                return String(localized: "System default · Shell not detected")
            }
            return String(
                format: String(localized: "System default · %@ (%@)"),
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
        VStack(alignment: .leading, spacing: 18) {
            group("AI providers") {
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

                    HStack(spacing: 8) {
                        Button("Add Provider") {
                            viewState.editingProviderID = settings.addAIProvider()
                            syncAIProviderDraft()
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())

                        Button("Remove") {
                            if let id = editingProvider?.id { settings.removeAIProvider(id) }
                            viewState.editingProviderID = nil
                            syncAIProviderDraft()
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                        .disabled(editingProvider == nil)
                    }
                }

                if editingProvider != nil {
                    TextField("Provider name", text: editingProviderTextBinding(\.name))
                        .litheSettingsTextField()
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
                    TextField("API URL", text: editingProviderTextBinding(\.endpoint))
                        .litheSettingsTextField()
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
                    TextField("Model", text: editingProviderTextBinding(\.model))
                        .litheSettingsTextField()
                        .disabled(editingProviderIsConfigurationManaged)

                    HStack(spacing: 8) {
                        SecureField("API key or token", text: $viewState.aiAPIKeyDraft)
                            .litheSettingsTextField()
                            .disabled(editingProviderIsConfigurationManaged)
                        Button("Save Key") {
                            if let editingProvider { model.saveAPIKey(viewState.aiAPIKeyDraft, for: editingProvider) }
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
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
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(LitheTheme.success)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(LocalizedStringKey(configuration.source.detectedTitle))
                                        .font(.system(size: 12, weight: .medium))
                                    Text("\(configuration.model) · \(configuration.endpoint)")
                                        .font(.system(size: 10.5, design: .monospaced))
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
                                .buttonStyle(LithePrimaryButtonStyle(
                                    backgroundColor: LitheTheme.settingsPrimaryAction,
                                    restingOpacity: 1
                                ))
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
                            .buttonStyle(LitheSecondaryButtonStyle())
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
                        .buttonStyle(LitheSecondaryButtonStyle())
                    }
                }

                if !editingProviderIsConfigurationManaged {
                    Text("API keys are stored in Lithe's local application data and are never written to Lithe settings.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }

        }
        .frame(maxWidth: 760, alignment: .leading)
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
        if settings.commitMessageAI.activeProviderID == provider.id { users.append(String(localized: "commit messages")) }
        users += settings.agentConfigurations.values
            .filter { $0.providerID == provider.id }
            .map(\.name)
            .sorted()
        return users.isEmpty
            ? String(localized: "Not used yet.")
            : String(format: String(localized: "Used by: %@"), users.joined(separator: ", "))
    }

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                    .buttonStyle(LitheSecondaryButtonStyle())
            }

            group("Commit message generation") {
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
                        .font(.system(size: 11.5, weight: .medium))
                    TextEditor(text: $settings.commitMessageAI.customInstructions)
                        .litheSettingsTextEditor(height: 92)
                }

                Text("Low effort and a small output limit are recommended for fast commit-message generation.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Pull request description generation") {
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
                    HStack {
                        Text("Markdown template")
                            .font(.system(size: 11.5, weight: .medium))
                        Spacer()
                        Button("Restore Default Template") {
                            settings.commitMessageAI.pullRequestCustomTemplate =
                                CommitMessageAISettings.defaultPullRequestTemplate
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .lithePointer()
                    }

                    TextEditor(text: $settings.commitMessageAI.pullRequestCustomTemplate)
                        .litheSettingsTextEditor(height: 150)

                    Text("Supported placeholders: {summary}, {changes}, {testing}, {risks}.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }

                Text("Pull request generation uses the selected provider, language, reasoning effort, and diff limit above.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)

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
        HStack(alignment: .top, spacing: 10) {
            Text("Format")
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 118, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    toggleFormatPicker()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: settings.commitMessageAI.format.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LitheTheme.accent)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(settings.commitMessageAI.format.title))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(LitheTheme.primaryText)
                            Text(LocalizedStringKey(settings.commitMessageAI.format.description))
                                .font(LitheTheme.smallFont)
                                .foregroundStyle(LitheTheme.secondaryText)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
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
                .popover(isPresented: $viewState.isFormatPickerPresented, arrowEdge: .bottom) {
                    formatPickerPopover
                }

                formatExample
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var formatPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a commit format")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                    Text("Each built-in preset includes a preview of the generated message.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }

                Spacer(minLength: 8)

                Button {
                    viewState.isFormatPickerPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? LitheTheme.accent : LitheTheme.secondaryText)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(LocalizedStringKey(format.title))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LitheTheme.primaryText)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(LitheTheme.accent)
                        }
                    }

                    Text(LocalizedStringKey(format.description))
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)

                    if format != .custom {
                        Text(LocalizedStringKey(format.example))
                            .font(.system(size: 10.5, design: .monospaced))
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)

                Text(LocalizedStringKey(settings.commitMessageAI.format.example))
                    .font(.system(size: 11, design: .monospaced))
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
        VStack(alignment: .leading, spacing: 18) {
            group("Application version") {
                row("Current version") {
                    Text(updateChecker.versionDescription)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .monospacedDigit()
                }
                Text("Lithe checks GitHub Releases for published updates.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Update status") {
                updateStatusDescription
                StableRollbackControl()

                HStack(spacing: 10) {
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
                        checkButton.buttonStyle(LitheSecondaryButtonStyle())
                    } else {
                        checkButton.buttonStyle(LithePrimaryButtonStyle(
                            backgroundColor: LitheTheme.settingsPrimaryAction,
                            restingOpacity: 1
                        ))
                    }

                    if case .waitingForTermination = updateChecker.status {
                        Button {
                            Task { await updateChecker.retryInstallation() }
                        } label: {
                            Label("Continue Installation", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                    }
                    if case .available(let version, _) = updateChecker.status {
                        Button {
                            Task { await updateChecker.installAvailableUpdate() }
                        } label: {
                            if updateChecker.isPreview {
                                Label("Install Preview", systemImage: "arrow.down.circle.fill")
                            } else {
                                Label("Update \(version)", systemImage: "arrow.down.circle.fill")
                            }
                        }
                        .buttonStyle(LithePrimaryButtonStyle(
                            backgroundColor: LitheTheme.settingsPrimaryAction,
                            restingOpacity: 1
                        ))
                        .disabled(updateChecker.isBusy)
                    }
                }
            }
        }
    }

    private var diagnosticsSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Diagnostic bundle") {
                Text("Package the redacted application log with an environment and performance snapshot into a zip you can attach to a bug report. Credentials, tokens, and home-directory paths are removed automatically, and you can review the file list before anything is written.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)

                Button {
                    model.diagnosticsFeature.presentExport()
                } label: {
                    Label("Export Diagnostics Bundle…", systemImage: "stethoscope")
                }
                .buttonStyle(LithePrimaryButtonStyle(
                    backgroundColor: LitheTheme.settingsPrimaryAction,
                    restingOpacity: 1
                ))
            }
        }
        .sheet(isPresented: Binding(
            get: { model.diagnosticsFeature.isPresented },
            set: { model.diagnosticsFeature.isPresented = $0 }
        )) {
            DiagnosticsExportSheet(feature: model.diagnosticsFeature)
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

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .fixedSize()
                Rectangle().fill(LitheTheme.divider).frame(height: 1)
            }
            content()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .fixedSize(horizontal: true, vertical: false)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
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
                .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 28))
            Spacer()
            HStack(spacing: 10) {
                Button { closeSettings() } label: {
                    Text("Cancel")
                        .frame(minWidth: Self.footerActionLabelWidth)
                }
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 10, height: 28))
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
                        .frame(minWidth: Self.footerActionLabelWidth)
                }
                    .buttonStyle(LithePrimaryButtonStyle(
                        backgroundColor: LitheTheme.settingsPrimaryAction,
                        restingOpacity: 1,
                        horizontalPadding: 10,
                        height: 28
                    ))
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewState.isApplyingPluginChanges)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(LitheTheme.settingsSurface)
    }

    private func syncVisibilityDrafts() {
        viewState.hiddenDirectoriesDraft = settings.hiddenDirectoryNames.joined(separator: "\n")
        viewState.hiddenFilePatternsDraft = settings.hiddenFilePatterns.joined(separator: "\n")
    }

    private func applyVisibilityDrafts() {
        settings.hiddenDirectoryNames = entries(from: viewState.hiddenDirectoriesDraft)
        settings.hiddenFilePatterns = entries(from: viewState.hiddenFilePatternsDraft)
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
