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
    @Published var isFormatPickerPresented = false

    init(initialCategory: SettingsCategory) {
        selection = initialCategory
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewState: SettingsViewState
    let initialCategory: SettingsCategory
    private let onDismiss: (() -> Void)?
    private static let footerActionLabelWidth: CGFloat = 52

    init(
        settings: AppSettings,
        viewState: SettingsViewState,
        initialCategory: SettingsCategory = .general,
        onDismiss: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.viewState = viewState
        self.initialCategory = initialCategory
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                categories
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                content
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(minWidth: 820, minHeight: 620)
        .background {
            LitheTheme.settingsSurface
                .ignoresSafeArea()
        }
        .onAppear {
            syncVisibilityDrafts()
            model.refreshAIConfigurations()
            syncAIProviderDraft()
        }
        .onChange(of: settings.hiddenDirectoryNames) { _ in syncVisibilityDrafts() }
        .onChange(of: settings.hiddenFilePatterns) { _ in syncVisibilityDrafts() }
        .onChange(of: settings.commitMessageAI.activeProviderID) { _ in syncAIProviderDraft() }
        .onChange(of: initialCategory) { category in
            viewState.searchQuery = ""
            viewState.selection = category
        }
        .onChange(of: viewState.searchQuery) { _ in
            guard !filteredCategories.contains(viewState.selection),
                  let firstMatch = filteredCategories.first else { return }
            viewState.selection = firstMatch
        }
        .environment(\.locale, settings.language.locale)
    }

    private var categories: some View {
        VStack(spacing: 0) {
            settingsSearchField
                .padding(12)

            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(filteredCategories) { category in
                        categoryButton(category)
                    }

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
                .padding(8)
            }
            .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
        }
        .frame(width: 244)
        .frame(maxHeight: .infinity)
        .background(LitheTheme.settingsSurface)
    }

    private var settingsSearchField: some View {
        LitheSettingsSearchField("Search settings", text: $viewState.searchQuery)
    }

    private func categoryButton(_ category: SettingsCategory) -> some View {
        let isSelected = viewState.selection == category
        return Button {
            viewState.selection = category
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18)
                Text(LocalizedStringKey(category.rawValue))
                    .font(.system(size: 12.5, weight: .regular))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: LitheTheme.Metrics.treeRowHeight)
            .background(isSelected ? LitheTheme.settingsSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(LitheTreeRowButtonStyle())
        .foregroundStyle(isSelected ? Color.white : LitheTheme.primaryText)
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
            ["General", "Appearance", "Color theme", "Appearance mode", "Language", "Projects", "Files", "Version control", "Logs", "Log directory"]
        case .editor:
            ["Editor", "Display", "Editor tabs", "Font size", "File tree row height", "Indentation", "Tab width"]
        case .keymap:
            ["Keymap", "Keyboard shortcuts", "Shortcuts", "Actions"]
        case .terminal:
            ["Terminal", "Shell", "Default shell"]
        case .lsp:
            ["LSP", "Language server", "Java SDK", "JDK", "Maven"]
        case .ai:
            ["AI & Commit", "AI provider", "Model", "API key", "Commit message"]
        case .updates:
            ["Updates", "Application version", "Update status", "Check for Updates"]
        }
    }

    private func localizedSearchValue(_ key: String) -> String {
        String(
            localized: String.LocalizationValue(key),
            bundle: .main,
            locale: settings.language.locale
        )
    }

    @ViewBuilder
    private var content: some View {
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
        } else if viewState.selection == .keymap {
            KeyboardShortcutSettingsView(
                feature: model.keyboardShortcutFeature,
                language: settings.language
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey(viewState.selection.rawValue))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .padding(.bottom, 8)

                    switch viewState.selection {
                    case .general: generalSettings
                    case .editor: editorSettings
                    case .keymap: EmptyView()
                    case .terminal: terminalSettings
                    case .lsp: EmptyView()
                    case .ai: aiSettings
                    case .updates: updatesSettings
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
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
                        width: 180,
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
            }

            group("Language") {
                row("Language") {
                    LitheSettingsSelect(
                        selection: $settings.language,
                        options: AppLanguage.allCases,
                        width: 180,
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
                        width: 180,
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
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 66)
                    .padding(5)
                    .litheRoundedControlBackground(LitheTheme.inputBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(LitheTheme.inputBorder, lineWidth: 1)
                    }

                Text("File patterns")
                    .font(.system(size: 11.5, weight: .medium))
                TextEditor(text: $viewState.hiddenFilePatternsDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 52)
                    .padding(5)
                    .litheRoundedControlBackground(LitheTheme.inputBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(LitheTheme.inputBorder, lineWidth: 1)
                    }

                HStack {
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
                    .buttonStyle(.plain)
                    .foregroundStyle(LitheTheme.secondaryText)
                    .contentShape(Rectangle())
                    .lithePointer()
                    .help("Choose Directory")
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(LitheTheme.inputBorder, lineWidth: 1)
                }

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
                        .buttonStyle(.plain)
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
                    selection: $settings.terminalShell,
                    options: TerminalShell.allCases,
                    width: 180,
                    accessibilityLabel: "Default shell",
                    title: \TerminalShell.title
                )
                .onChange(of: settings.terminalShell) { _ in
                    guard model.activeTerminalSession?.isRunning == true else { return }
                    model.restartActiveTerminal(using: model.activeTerminalShellPath)
                }
            }
            Text("Used for new terminal sessions.")
                .font(LitheTheme.smallFont)
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var aiSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("AI provider") {
                if settings.commitMessageAI.providers.isEmpty {
                    Text("No AI provider is configured yet.")
                        .foregroundStyle(LitheTheme.secondaryText)
                } else {
                    row("Profile") {
                        LitheSettingsSelect(
                            selection: Binding(
                                get: { settings.commitMessageAI.activeProviderID ?? settings.commitMessageAI.providers[0].id },
                                set: { settings.selectCommitMessageProvider($0) }
                            ),
                            options: settings.commitMessageAI.providers.map(\.id),
                            width: 240,
                            accessibilityLabel: "Profile",
                            title: providerTitle
                        )
                    }

                    HStack(spacing: 8) {
                        Button("Add Provider") {
                            settings.addCommitMessageProvider()
                            syncAIProviderDraft()
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())

                        Button("Remove") {
                            settings.removeActiveCommitMessageProvider()
                            syncAIProviderDraft()
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                        .disabled(settings.activeCommitMessageProvider == nil)
                    }
                }

                if settings.activeCommitMessageProvider != nil {
                    TextField("Provider name", text: activeProviderTextBinding(\.name))
                        .litheSettingsTextField()
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    row("API protocol") {
                        LitheSettingsSelect(
                            selection: activeProviderProtocolBinding(),
                            options: CommitMessageAPIProtocol.allCases,
                            width: 240,
                            accessibilityLabel: "API protocol",
                            title: \CommitMessageAPIProtocol.title
                        )
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    }
                    TextField("API URL", text: activeProviderTextBinding(\.endpoint))
                        .litheSettingsTextField()
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    if settings.activeCommitMessageProvider?.usesInsecureHTTP == true {
                        LitheSettingsCheckbox(
                            isOn: activeProviderBoolBinding(\.allowsInsecureHTTP),
                            title: "Allow insecure HTTP"
                        )
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                        Label(
                            settings.activeCommitMessageProvider?.allowsInsecureHTTP == true
                                ? "HTTP sends the API credential without encryption. Use only a trusted endpoint."
                                : "HTTP is blocked until you explicitly allow it for this provider.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.warning)
                    }
                    TextField("Model", text: activeProviderTextBinding(\.model))
                        .litheSettingsTextField()
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)

                    HStack(spacing: 8) {
                        SecureField("API key or token", text: $viewState.aiAPIKeyDraft)
                            .litheSettingsTextField()
                            .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                        Button("Save Key") {
                            model.saveActiveCommitMessageAPIKey(viewState.aiAPIKeyDraft)
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    }

                    LitheSettingsCheckbox(
                        isOn: activeProviderBoolBinding(\.requiresAPIKey),
                        title: "Provider requires an API key"
                    )
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)

                    if model.activeCommitMessageCredentialIsConfigurationManaged,
                       let description = model.activeCommitMessageConfigurationSourceDescription {
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

                if !model.activeCommitMessageCredentialIsConfigurationManaged {
                    Text("API keys are stored in Lithe's local application data and are never written to Lithe settings.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
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
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 92)
                        .padding(5)
                        .litheRoundedControlBackground(LitheTheme.inputBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                                .stroke(LitheTheme.inputBorder, lineWidth: 1)
                        }
                }

                Text("Low effort and a small output limit are recommended for fast commit-message generation.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Pull request description generation") {
                Picker("Description format", selection: $settings.commitMessageAI.pullRequestFormat) {
                    ForEach(PullRequestDescriptionFormat.allCases) { format in
                        Text(LocalizedStringKey(format.title)).tag(format)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
                .lithePointer()

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
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 150)
                        .padding(5)
                        .background(LitheTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                                .stroke(LitheTheme.inputBorder, lineWidth: 1)
                        }

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
                    .background(viewState.isFormatPickerPresented ? LitheTheme.inputBackground.opacity(0.9) : LitheTheme.inputBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(
                                viewState.isFormatPickerPresented ? LitheTheme.inputFocusBorder : LitheTheme.inputBorder,
                                lineWidth: 1
                            )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                }
                .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(LitheTheme.inputBorder, lineWidth: 1)
                    }
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
                    Text(updateChecker.currentVersion)
                        .foregroundStyle(LitheTheme.secondaryText)
                        .monospacedDigit()
                }
                Text("Lithe checks GitHub Releases for published updates.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Update status") {
                updateStatusDescription

                HStack(spacing: 10) {
                    Button {
                        Task { await updateChecker.checkForUpdates(manual: true) }
                    } label: {
                        Label(
                            updateChecker.isChecking ? "Checking for updates…" : "Check for Updates",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(LithePrimaryButtonStyle(
                        backgroundColor: LitheTheme.settingsPrimaryAction,
                        restingOpacity: 1
                    ))
                    .disabled(updateChecker.isBusy)

                    if case .available(let version, _) = updateChecker.status {
                        Button {
                            Task { await updateChecker.installAvailableUpdate() }
                        } label: {
                            Label("Update \(version)", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(LitheSecondaryButtonStyle())
                        .disabled(updateChecker.isBusy)
                    }
                }
            }
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
                Text(progress.byteCountDescription)
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.tertiaryText)
            }
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
        case .noRelease:
            Text("No published release is available yet.")
                .foregroundStyle(LitheTheme.secondaryText)
        case .failed:
            Label("Could not check for updates.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(LitheTheme.warning)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            content()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            content()
        }
        .frame(minHeight: 28)
    }

    private func syncAIProviderDraft() {
        viewState.aiAPIKeyDraft = model.activeCommitMessageAPIKey
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

    private func activeProviderTextBinding(
        _ keyPath: WritableKeyPath<AIProviderProfile, String>
    ) -> Binding<String> {
        Binding(
            get: { settings.activeCommitMessageProvider?[keyPath: keyPath] ?? "" },
            set: { value in
                settings.updateActiveCommitMessageProvider { provider in
                    provider[keyPath: keyPath] = value
                }
            }
        )
    }

    private func activeProviderProtocolBinding() -> Binding<CommitMessageAPIProtocol> {
        Binding(
            get: { settings.activeCommitMessageProvider?.apiProtocol ?? .responses },
            set: { value in
                settings.updateActiveCommitMessageProvider { provider in
                    provider.apiProtocol = value
                }
            }
        )
    }

    private func activeProviderBoolBinding(
        _ keyPath: WritableKeyPath<AIProviderProfile, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { settings.activeCommitMessageProvider?[keyPath: keyPath] ?? true },
            set: { value in
                settings.updateActiveCommitMessageProvider { provider in
                    provider[keyPath: keyPath] = value
                }
            }
        )
    }


    private var footer: some View {
        HStack {
            Button("Restore Defaults") { settings.restoreDefaults() }
                .buttonStyle(LitheSecondaryButtonStyle())
            Spacer()
            HStack(spacing: 10) {
                Button { closeSettings() } label: {
                    Text("Cancel")
                        .frame(minWidth: Self.footerActionLabelWidth)
                }
                    .buttonStyle(LitheSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { closeSettings() } label: {
                    Text("OK")
                        .frame(minWidth: Self.footerActionLabelWidth)
                }
                    .buttonStyle(LithePrimaryButtonStyle(
                        backgroundColor: LitheTheme.settingsPrimaryAction,
                        restingOpacity: 1
                    ))
                    .keyboardShortcut(.defaultAction)
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
