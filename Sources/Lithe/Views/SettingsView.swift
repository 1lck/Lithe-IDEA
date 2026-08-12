import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @ObservedObject var settings: AppSettings
    @ObservedObject var projectRuntime: RuntimeSettingsFeatureModel
    @State private var selection: SettingsCategory
    @State private var hiddenDirectoriesDraft = ""
    @State private var hiddenFilePatternsDraft = ""
    @State private var javaHomeDraft = ""
    @State private var mavenHomeDraft = ""
    @State private var mavenJavaHomeDraft = ""
    @State private var aiAPIKeyDraft = ""
    @State private var isFormatPickerPresented = false

    init(
        settings: AppSettings,
        runtimeFeature: RuntimeSettingsFeatureModel,
        initialCategory: SettingsCategory = .general
    ) {
        self.settings = settings
        projectRuntime = runtimeFeature
        _selection = State(initialValue: initialCategory)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 0) {
                categories
                Rectangle().fill(LitheTheme.divider).frame(width: 1)
                content
            }
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            footer
        }
        .frame(width: 820, height: 620)
        .background(LitheTheme.window)
        .onAppear {
            syncVisibilityDrafts()
            syncRuntimeDrafts()
            model.refreshAIConfigurations()
            syncAIProviderDraft()
        }
        .onChange(of: settings.hiddenDirectoryNames) { _ in syncVisibilityDrafts() }
        .onChange(of: settings.hiddenFilePatterns) { _ in syncVisibilityDrafts() }
        .onChange(of: projectRuntime.settings.javaHomePath) { _ in javaHomeDraft = projectRuntime.settings.javaHomePath }
        .onChange(of: projectRuntime.settings.mavenHomePath) { _ in mavenHomeDraft = projectRuntime.settings.mavenHomePath }
        .onChange(of: projectRuntime.settings.mavenJavaHomePath) { _ in mavenJavaHomeDraft = projectRuntime.settings.mavenJavaHomePath }
        .onChange(of: settings.commitMessageAI.activeProviderID) { _ in syncAIProviderDraft() }
        .onDisappear(perform: commitRuntimeDrafts)
    }

    private var header: some View {
        HStack(spacing: 9) {
            LitheSystemIcon(systemImage: "gearshape.fill")
                .foregroundStyle(LitheTheme.secondaryText)
            Text("Settings")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .litheIconButton()
            .help("Close Settings")
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(LitheTheme.toolHeader)
    }

    private var categories: some View {
        VStack(spacing: 3) {
            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selection = category
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: category.icon).frame(width: 18)
                        Text(LocalizedStringKey(category.rawValue))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
                    .background(selection == category ? LitheTheme.selection : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .lithePointer()
                .foregroundStyle(selection == category ? Color.white : LitheTheme.primaryText)
            }
            Spacer()
        }
        .font(.system(size: 12.5))
        .padding(8)
        .frame(width: 190)
        .background(LitheTheme.sidebar)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(LocalizedStringKey(selection.rawValue))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(LitheTheme.primaryText)

                switch selection {
                case .project: projectSettings
                case .general: generalSettings
                case .editor: editorSettings
                case .terminal: terminalSettings
                case .ai: aiSettings
                case .updates: updatesSettings
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var projectSettings: some View {
        if let workspaceURL = model.workspaceURL {
            VStack(alignment: .leading, spacing: 18) {
                Text(workspaceURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .textSelection(.enabled)

                group("Java SDK") {
                    runtimePickerRow(
                        title: "Project JDK",
                        selection: Binding(
                            get: { projectRuntime.settings.javaHomePath },
                            set: { projectRuntime.updateJavaHomePath($0) }
                        ),
                        automaticTitle: "Use detected system JDK",
                        options: projectRuntime.javaRuntimes.map { ($0.homePath, $0.displayName) }
                    )
                    runtimePathRow(
                        title: "JDK Home",
                        placeholder: "Choose a JDK directory",
                        text: $javaHomeDraft,
                        onCommit: { projectRuntime.updateJavaHomePath(javaHomeDraft) }
                    )
                    runtimeStatusRow(
                        title: "Effective JDK",
                        value: projectRuntime.activeJavaRuntime().map {
                            "\($0.displayName) · \($0.homePath)"
                        } ?? "System JDK not resolved"
                    )
                }

                group("Maven") {
                    Picker("Maven source", selection: Binding(
                        get: { projectRuntime.settings.mavenHomeSelection },
                        set: { projectRuntime.updateMavenHomeSelection($0) }
                    )) {
                        ForEach(MavenHomeSelection.allCases) { selection in
                            Text(LocalizedStringKey(selection.title)).tag(selection)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)
                    .lithePointer()

                    if projectRuntime.settings.mavenHomeSelection == .custom {
                        runtimePathRow(
                            title: "Maven Home",
                            placeholder: "Choose Maven home or bin/mvn",
                            text: $mavenHomeDraft,
                            onCommit: { projectRuntime.updateMavenHomePath(mavenHomeDraft) }
                        )
                    } else {
                        Text("Automatic uses a project mvnw first, then the system Maven on PATH.")
                            .font(LitheTheme.smallFont)
                            .foregroundStyle(LitheTheme.secondaryText)
                    }

                    runtimePathRow(
                        title: "Maven JDK",
                        placeholder: "Use project JDK",
                        text: $mavenJavaHomeDraft,
                        onCommit: { projectRuntime.updateMavenJavaHomePath(mavenJavaHomeDraft) }
                    )
                    runtimeStatusRow(
                        title: "Detected Maven",
                        value: detectedMavenStatus
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await projectRuntime.refreshAvailableRuntimes() }
                    } label: {
                        Label(
                            projectRuntime.isDiscovering ? "Discovering…" : "Refresh detected runtimes",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(projectRuntime.isDiscovering)
                    .lithePointer()

                    Text("Project runtime settings are saved locally for this project.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Open a project to configure its JDK and Maven runtime.")
                    .foregroundStyle(LitheTheme.secondaryText)
                Text("Application-wide editor and terminal settings remain available in the other categories.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }
        }
    }

    private var detectedMavenStatus: String {
        guard let project = model.mavenFeature.project else {
            return projectRuntime.isDiscovering ? "Discovering Maven…" : "No Maven project detected"
        }
        if projectRuntime.settings.mavenHomeSelection == .wrapper {
            return projectRuntime.mavenExecutable(for: project)?.path ?? "Maven Wrapper is not executable"
        }
        if let runtime = projectRuntime.activeMavenRuntime(for: project) {
            return "\(runtime.displayName) · \(runtime.executablePath)"
        }
        return projectRuntime.mavenExecutable(for: project)?.path ?? "Maven executable not resolved"
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Appearance") {
                row("Color theme") {
                    Picker("", selection: $settings.colorTheme) {
                        ForEach(AppColorTheme.allCases) { theme in
                            Text(LocalizedStringKey(theme.title)).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180, alignment: .leading)
                    .lithePointer()
                }

                row("Appearance mode") {
                    Picker("", selection: $settings.themePreference) {
                        ForEach(AppThemePreference.allCases) { preference in
                            Text(LocalizedStringKey(preference.title)).tag(preference)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .lithePointer()
                }

                Text("Choose a color theme and whether Lithe follows the system appearance.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Language") {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                .lithePointer()

                Text("The interface language changes immediately. English is the default.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Projects") {
                Picker("Open projects in", selection: $settings.projectOpenBehavior) {
                    ForEach(ProjectOpenBehavior.allCases) { behavior in
                        Text(LocalizedStringKey(behavior.title)).tag(behavior)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                .lithePointer()

                Text("Choose whether opening another project asks first, stays in this window, or creates a new window.")
                    .font(LitheTheme.smallFont)
                    .foregroundStyle(LitheTheme.secondaryText)
            }

            group("Files") {
                Toggle("Save changed files automatically", isOn: $settings.autoSave)
                    .lithePointer()
                if settings.autoSave {
                    row("Save after") {
                        Picker("", selection: $settings.autoSaveDelay) {
                            Text("0.5 seconds").tag(0.5)
                            Text("1.5 seconds").tag(1.5)
                            Text("3 seconds").tag(3.0)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .lithePointer()
                    }
                }
            }

            group("Git") {
                Picker("Save local changes with", selection: $settings.gitSaveChangesPolicy) {
                    ForEach(GitSaveChangesPolicy.allCases) { policy in
                        Text(LocalizedStringKey(policy.title)).tag(policy)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
                .lithePointer()

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
                TextEditor(text: $hiddenDirectoriesDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 66)
                    .padding(5)
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(LitheTheme.inputBorder, lineWidth: 1)
                    }

                Text("File patterns")
                    .font(.system(size: 11.5, weight: .medium))
                TextEditor(text: $hiddenFilePatternsDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 52)
                    .padding(5)
                    .background(LitheTheme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(LitheTheme.inputBorder, lineWidth: 1)
                    }

                HStack {
                    Spacer()
                    Button("Apply") { applyVisibilityDrafts() }
                        .buttonStyle(.borderedProminent)
                        .lithePointer()
                        .tint(LitheTheme.accent)
                }
            }
        }
    }

    private var editorSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Display") {
                row("Font size") {
                    Stepper(value: $settings.editorFontSize, in: 10...22, step: 1) {
                        Text("\(Int(settings.editorFontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                    .lithePointer()
                }
                Toggle("Show usages and Git author", isOn: $settings.showCodeVision)
                    .lithePointer()
            }
            group("Editor tabs") {
                row("Layout") {
                    Picker("", selection: $settings.editorTabLayoutMode) {
                        ForEach(EditorTabLayoutMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.title)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .lithePointer()
                }
            }
            group("Indentation") {
                row("Tab width") {
                    Picker("", selection: $settings.tabWidth) {
                        Text("2 spaces").tag(2)
                        Text("4 spaces").tag(4)
                        Text("8 spaces").tag(8)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .lithePointer()
                }
            }
        }
    }

    private var terminalSettings: some View {
        group("Shell") {
            row("Default shell") {
                Picker("", selection: $settings.terminalShell) {
                    ForEach(TerminalShell.allCases) { shell in
                        Text(LocalizedStringKey(shell.title)).tag(shell)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .lithePointer()
                .onChange(of: settings.terminalShell) { _ in
                    guard model.activeTerminalSession?.isRunning == true else { return }
                    let path = settings.terminalShellPath
                        ?? ProcessInfo.processInfo.environment["SHELL"]
                        ?? "/bin/zsh"
                    model.restartActiveTerminal(using: path)
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
                    Picker("Profile", selection: Binding(
                        get: { settings.commitMessageAI.activeProviderID ?? settings.commitMessageAI.providers[0].id },
                        set: { settings.selectCommitMessageProvider($0) }
                    )) {
                        ForEach(settings.commitMessageAI.providers) { provider in
                            Text(provider.name.isEmpty ? "Unnamed provider" : provider.name)
                                .tag(provider.id)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .lithePointer()

                    HStack(spacing: 8) {
                        Button("Add Provider") {
                            settings.addCommitMessageProvider()
                            syncAIProviderDraft()
                        }
                        .buttonStyle(.bordered)
                        .lithePointer()

                        Button("Remove") {
                            settings.removeActiveCommitMessageProvider()
                            syncAIProviderDraft()
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.activeCommitMessageProvider == nil)
                        .lithePointer()
                    }
                }

                if settings.activeCommitMessageProvider != nil {
                    TextField("Provider name", text: activeProviderTextBinding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    Picker("API protocol", selection: activeProviderProtocolBinding()) {
                        ForEach(CommitMessageAPIProtocol.allCases) { apiProtocol in
                            Text(LocalizedStringKey(apiProtocol.title)).tag(apiProtocol)
                        }
                    }
                    .frame(maxWidth: 300, alignment: .leading)
                    .lithePointer()
                    .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    TextField("API URL", text: activeProviderTextBinding(\.endpoint))
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    if settings.activeCommitMessageProvider?.usesInsecureHTTP == true {
                        Toggle(
                            "Allow insecure HTTP",
                            isOn: activeProviderBoolBinding(\.allowsInsecureHTTP)
                        )
                        .lithePointer()
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
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)

                    HStack(spacing: 8) {
                        SecureField("API key or token", text: $aiAPIKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                        Button("Save Key") {
                            model.saveActiveCommitMessageAPIKey(aiAPIKeyDraft)
                        }
                        .buttonStyle(.bordered)
                        .lithePointer()
                        .disabled(model.activeCommitMessageCredentialIsConfigurationManaged)
                    }

                    Toggle("Provider requires an API key", isOn: activeProviderBoolBinding(\.requiresAPIKey))
                        .lithePointer()
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
                                .buttonStyle(.borderedProminent)
                                .tint(LitheTheme.accent)
                                .lithePointer()
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
                            .buttonStyle(.bordered)
                            .lithePointer()
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
                        .buttonStyle(.bordered)
                        .lithePointer()
                    }
                }

                if !model.activeCommitMessageCredentialIsConfigurationManaged {
                    Text("API keys are stored in Lithe's local application data and are never written to Lithe settings.")
                        .font(LitheTheme.smallFont)
                        .foregroundStyle(LitheTheme.secondaryText)
                }
            }

            group("Commit message generation") {
                Picker("Reasoning effort", selection: $settings.commitMessageAI.reasoningEffort) {
                    ForEach(CommitMessageReasoningEffort.allCases) { effort in
                        Text(LocalizedStringKey(effort.title)).tag(effort)
                    }
                }
                .frame(maxWidth: 230, alignment: .leading)
                .lithePointer()

                Picker("Output language", selection: $settings.commitMessageAI.language) {
                    ForEach(CommitMessageLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.title)).tag(language)
                    }
                }
                .frame(maxWidth: 230, alignment: .leading)
                .lithePointer()

                formatPicker

                Toggle("Include a short body when useful", isOn: $settings.commitMessageAI.includeBody)
                    .lithePointer()

                row("Subject maximum length") {
                    Stepper(value: $settings.commitMessageAI.subjectMaximumLength, in: 40...120, step: 4) {
                        Text("\(settings.commitMessageAI.subjectMaximumLength) ") + Text("chars")
                            .monospacedDigit()
                    }
                    .lithePointer()
                }

                row("Diff character limit") {
                    Stepper(value: $settings.commitMessageAI.maximumDiffCharacters, in: 8_000...120_000, step: 4_000) {
                        Text("\(settings.commitMessageAI.maximumDiffCharacters)")
                            .monospacedDigit()
                    }
                    .lithePointer()
                }

                if settings.commitMessageAI.format == .custom {
                    Text("Custom instructions")
                        .font(.system(size: 11.5, weight: .medium))
                    TextEditor(text: $settings.commitMessageAI.customInstructions)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 92)
                        .padding(5)
                        .background(LitheTheme.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                                .stroke(LitheTheme.inputBorder, lineWidth: 1)
                        }
                }

                Text("Low effort and a small output limit are recommended for fast commit-message generation.")
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
                            .rotationEffect(.degrees(isFormatPickerPresented ? 180 : 0))
                            .animation(formatPickerAnimation, value: isFormatPickerPresented)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(isFormatPickerPresented ? LitheTheme.inputBackground.opacity(0.9) : LitheTheme.inputBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius)
                            .stroke(
                                isFormatPickerPresented ? LitheTheme.inputFocusBorder : LitheTheme.inputBorder,
                                lineWidth: 1
                            )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: LitheTheme.Metrics.controlCornerRadius))
                }
                .buttonStyle(.plain)
                .lithePointer()
                .popover(isPresented: $isFormatPickerPresented, arrowEdge: .bottom) {
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
                    isFormatPickerPresented = false
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
            isFormatPickerPresented.toggle()
        }
    }

    private func selectFormat(_ format: CommitMessageFormat) {
        withAnimation(formatPickerAnimation) {
            settings.commitMessageAI.format = format
            isFormatPickerPresented = false
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
                    .buttonStyle(.borderedProminent)
                    .tint(LitheTheme.accent)
                    .disabled(updateChecker.isBusy)
                    .lithePointer()

                    if case .available(let version, _) = updateChecker.status {
                        Button {
                            Task { await updateChecker.installAvailableUpdate() }
                        } label: {
                            Label("Update \(version)", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .disabled(updateChecker.isBusy)
                        .lithePointer()
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitheTheme.sidebar)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(LitheTheme.divider, lineWidth: 1) }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            content()
        }
        .frame(minHeight: 28)
    }

    private func runtimePickerRow(
        title: String,
        selection: Binding<String>,
        automaticTitle: String,
        options: [(String, String)]
    ) -> some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 118, alignment: .leading)
            Picker("", selection: selection) {
                Text(LocalizedStringKey(automaticTitle)).tag("")
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .lithePointer()
        }
    }

    private func runtimePathRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 118, alignment: .leading)
            TextField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCommit)
            Button {
                chooseDirectory {
                    text.wrappedValue = $0
                    onCommit()
                }
            } label: {
                LitheSystemIcon(systemImage: "folder")
            }
            .litheIconButton()
            .help("Choose directory")
        }
        .font(.system(size: 12))
    }

    private func syncRuntimeDrafts() {
        javaHomeDraft = projectRuntime.settings.javaHomePath
        mavenHomeDraft = projectRuntime.settings.mavenHomePath
        mavenJavaHomeDraft = projectRuntime.settings.mavenJavaHomePath
    }

    private func syncAIProviderDraft() {
        aiAPIKeyDraft = model.activeCommitMessageAPIKey
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

    private func commitRuntimeDrafts() {
        if javaHomeDraft != projectRuntime.settings.javaHomePath {
            projectRuntime.updateJavaHomePath(javaHomeDraft)
        }
        if mavenHomeDraft != projectRuntime.settings.mavenHomePath {
            projectRuntime.updateMavenHomePath(mavenHomeDraft)
        }
        if mavenJavaHomeDraft != projectRuntime.settings.mavenJavaHomePath {
            projectRuntime.updateMavenJavaHomePath(mavenJavaHomeDraft)
        }
    }

    private func runtimeStatusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 118, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(LitheTheme.primaryText)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func chooseDirectory(onChange: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose Runtime Directory"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onChange(url.path)
        }
    }

    private var footer: some View {
        HStack {
            Button("Restore Defaults") { settings.restoreDefaults() }
                .buttonStyle(.borderless)
                .lithePointer()
                .foregroundStyle(LitheTheme.secondaryText)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .lithePointer()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(LitheTheme.toolHeader)
    }

    private func syncVisibilityDrafts() {
        hiddenDirectoriesDraft = settings.hiddenDirectoryNames.joined(separator: "\n")
        hiddenFilePatternsDraft = settings.hiddenFilePatterns.joined(separator: "\n")
    }

    private func applyVisibilityDrafts() {
        settings.hiddenDirectoryNames = entries(from: hiddenDirectoriesDraft)
        settings.hiddenFilePatterns = entries(from: hiddenFilePatternsDraft)
    }

    private func entries(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
