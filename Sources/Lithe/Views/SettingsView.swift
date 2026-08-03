import AppKit
import SwiftUI

struct SettingsView: View {
    enum Category: String, CaseIterable, Identifiable {
        case project = "Project"
        case general = "General"
        case editor = "Editor"
        case terminal = "Terminal"
        case updates = "Updates"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .project: "folder.badge.gearshape"
            case .general: "gearshape"
            case .editor: "textformat"
            case .terminal: "terminal"
            case .updates: "arrow.down.circle"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updateChecker: UpdateChecker
    @ObservedObject var settings: AppSettings
    @ObservedObject var projectRuntime: ProjectRuntimeService
    @State private var selection: Category = .general
    @State private var hiddenDirectoriesDraft = ""
    @State private var hiddenFilePatternsDraft = ""
    @State private var javaHomeDraft = ""
    @State private var mavenHomeDraft = ""
    @State private var mavenJavaHomeDraft = ""

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
        .preferredColorScheme(.dark)
        .onAppear {
            syncVisibilityDrafts()
            syncRuntimeDrafts()
        }
        .onChange(of: settings.hiddenDirectoryNames) { syncVisibilityDrafts() }
        .onChange(of: settings.hiddenFilePatterns) { syncVisibilityDrafts() }
        .onChange(of: projectRuntime.settings.javaHomePath) { javaHomeDraft = projectRuntime.settings.javaHomePath }
        .onChange(of: projectRuntime.settings.mavenHomePath) { mavenHomeDraft = projectRuntime.settings.mavenHomePath }
        .onChange(of: projectRuntime.settings.mavenJavaHomePath) { mavenJavaHomeDraft = projectRuntime.settings.mavenJavaHomePath }
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
            ForEach(Category.allCases) { category in
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
        guard let project = model.mavenService.project else {
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
            group("Language") {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                .lithePointer()

                Text("The interface language changes immediately. English is the default.")
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
                .onChange(of: settings.terminalShell) {
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
        case .downloading(let version):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Downloading update \(version)…")
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
