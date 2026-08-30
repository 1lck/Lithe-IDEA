import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct RunConfigurationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: RunFeatureModel
    let configuration: RunConfiguration
    @State private var options: RunOptions
    @State private var projectToolchain: ProjectToolchainSelection
    @State private var environmentText: String
    @State private var saveScope: RunConfigurationSaveScope = .local
    @State private var saveError: String?
    @State private var activePathPicker: PathPicker?
    @State private var isPathPickerPresented = false

    init(feature: RunFeatureModel, configuration: RunConfiguration) {
        self.feature = feature
        self.configuration = configuration
        let initialOptions = feature.options(for: configuration)
        let projectToolchain = feature.projectToolchain
        _options = State(initialValue: Self.configurationOverrides(initialOptions, defaults: projectToolchain))
        _projectToolchain = State(initialValue: projectToolchain)
        _environmentText = State(initialValue: Self.environmentText(from: initialOptions.environment))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    saveScopeSection
                    configurationSummary
                    projectToolchainSection
                    runtimeSection
                    argumentsSection
                    if effectiveCapabilities.contains(.environment) {
                        environmentSection
                    }
                    if effectiveCapabilities.contains(.mavenSkipTests)
                        || (effectiveCapabilities.contains(.mavenProfiles) && !feature.mavenProfiles.isEmpty) {
                        mavenOptionsSection
                    }
                }
                .padding(18)
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Button("Reset") {
                    options = RunOptions()
                    projectToolchain = ProjectToolchainSelection()
                    environmentText = ""
                }
                .buttonStyle(.borderless)
                .lithePointer()
                .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                if let saveError {
                    Text(saveError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(LitheTheme.error)
                        .lineLimit(2)
                        .frame(maxWidth: 250, alignment: .trailing)
                }
                Button("Done") {
                    options.environment = Self.environment(from: environmentText)
                    guard let scopedOptions = scopedOptionsForSave() else { return }
                    if feature.saveEditorChanges(
                        scopedOptions,
                        toolchain: projectToolchain,
                        for: configuration,
                        scope: saveScope
                    ) {
                        dismiss()
                    } else {
                        saveError = feature.configurationSaveError
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .lithePointer()
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(LitheTheme.toolHeader)
        }
        .frame(width: 520, height: 470)
        .background(LitheTheme.window)
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $isPathPickerPresented,
            allowedContentTypes: activePathPicker?.allowedContentTypes ?? [.folder]
        ) { result in
            selectPath(result)
        }
    }

    private var effectiveCapabilities: RunConfigurationCapabilities {
        configuration.effectiveCapabilities(
            for: model.activeDocument?.url,
            catalog: model.languageProviderCatalog
        )
    }

    private var saveScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            Picker("Save scope", selection: $saveScope) {
                Text("This Mac").tag(RunConfigurationSaveScope.local)
                Text("Project").tag(RunConfigurationSaveScope.project)
            }
            .pickerStyle(.segmented)
            Text(saveScope == .local
                 ? "Saved in .lithe/run/local.json and excluded from Git."
                 : "Saved in .lithe/run/configurations.json for the whole team. Local JDK paths are never shared.")
                .font(.system(size: 11))
                .foregroundStyle(LitheTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            RunConfigurationIcon(kind: configuration.kind, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Configuration")
                    .font(.system(size: 14, weight: .semibold))
                Text(configuration.name)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .litheIconButton()
            .help("Close run configuration")
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(LitheTheme.toolHeader)
    }

    private var configurationSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Configuration")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            summaryRow(title: "Type", value: configuration.kind.title)
            summaryRow(title: "Effective source", value: sourceTitle)
            if let mainClass = configuration.mainClass {
                summaryRow(title: "Main class", value: mainClass)
            }
            if let modulePath = configuration.modulePath {
                summaryRow(title: "Maven module", value: modulePath)
            }
        }
    }

    private var sourceTitle: String {
        switch feature.source(for: configuration) {
        case .generated: "Automatically generated"
        case .project: "Project configuration"
        case .local: "This Mac"
        }
    }

    private var runtimeSection: some View {
        section(title: "Configuration overrides") {
            if effectiveCapabilities.contains(.javaRuntime) {
                pathRow(
                    title: "JDK Home",
                    placeholder: "Use project default",
                    text: stringBinding(\.javaHomePath),
                    chooseDirectory: { chooseDirectory(for: \.javaHomePath) }
                )
            }
            if configuration.kind.isMavenBacked {
                pathRow(
                    title: "Maven home or executable",
                    placeholder: "Use project default",
                    text: stringBinding(\.mavenExecutablePath),
                    chooseDirectory: { chooseFileOrDirectory(for: \.mavenExecutablePath) },
                    chooseHelp: "Choose Maven executable or home"
                )
                pathRow(
                    title: "Maven JDK Home",
                    placeholder: "Use project default",
                    text: stringBinding(\.mavenJavaHomePath),
                    chooseDirectory: { chooseDirectory(for: \.mavenJavaHomePath) }
                )
            }
            pathRow(
                title: "Working directory",
                placeholder: "Use project or file directory",
                text: stringBinding(\.workingDirectoryPath),
                chooseDirectory: { chooseDirectory(for: \.workingDirectoryPath) }
            )
        }
    }

    private var projectToolchainSection: some View {
        section(title: "Project defaults (This Mac)") {
            if effectiveCapabilities.contains(.javaRuntime) {
                pathRow(
                    title: "JDK Home",
                    placeholder: "Use detected JDK",
                    text: projectToolchainBinding(\.javaHomePath),
                    chooseDirectory: { chooseProjectToolchainDirectory(for: \.javaHomePath) }
                )
            }
            if configuration.kind.isMavenBacked {
                pathRow(
                    title: "Maven home or executable",
                    placeholder: "Use mvnw or detected Maven",
                    text: projectToolchainBinding(\.mavenExecutablePath),
                    chooseDirectory: { chooseProjectToolchainFileOrDirectory(for: \.mavenExecutablePath) },
                    chooseHelp: "Choose Maven executable or home"
                )
                pathRow(
                    title: "Maven JDK Home",
                    placeholder: "Use project JDK",
                    text: projectToolchainBinding(\.mavenJavaHomePath),
                    chooseDirectory: { chooseProjectToolchainDirectory(for: \.mavenJavaHomePath) }
                )
            }
        }
    }

    private var argumentsSection: some View {
        section(title: "Arguments") {
            if effectiveCapabilities.contains(.javaVMArguments) {
                argumentField(
                    title: "VM options",
                    placeholder: "-Xmx1g -Dserver.port=8080",
                    text: stringBinding(\.vmArguments)
                )
            }
            argumentField(
                title: "Program arguments",
                placeholder: configuration.kind.isMavenBacked
                    ? "--spring.profiles.active=dev"
                    : "Arguments passed to the program",
                text: stringBinding(\.arguments)
            )
        }
    }

    private var environmentSection: some View {
        section(title: "Environment") {
            TextEditor(text: $environmentText)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(minHeight: 72)
                .padding(5)
                .litheRoundedControlBackground(LitheTheme.inputBackground, cornerRadius: 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(LitheTheme.divider, lineWidth: 1)
                }
            Text("One NAME=value entry per line")
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var mavenOptionsSection: some View {
        section(title: "Maven") {
            if effectiveCapabilities.contains(.mavenSkipTests) {
                Picker("Tests", selection: Binding(
                    get: { options.mavenSkipTests },
                    set: { options.mavenSkipTests = $0 }
                )) {
                    Text("Project default").tag(Bool?.none)
                    Text("Run tests").tag(Bool?.some(false))
                    Text("Skip tests").tag(Bool?.some(true))
                }
                .pickerStyle(.segmented)
            }
            if effectiveCapabilities.contains(.mavenProfiles) {
                ForEach(feature.mavenProfiles) { profile in
                    Toggle(isOn: profileBinding(for: profile)) {
                        HStack(spacing: 0) {
                            Text(profile.id)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .toggleStyle(.checkbox)
                    .lithePointer()
                    .font(.system(size: 12))
                    .foregroundStyle(LitheTheme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LitheTheme.secondaryText)
            content()
        }
    }

    private func summaryRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    private func pathRow(
        title: String,
        placeholder: String,
        text: Binding<String>,
        chooseDirectory: @escaping () -> Void,
        chooseHelp: String = "Choose directory"
    ) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 120, alignment: .leading)
            TextField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
            Button(action: chooseDirectory) {
                LitheSystemIcon(systemImage: "folder")
            }
            .litheIconButton()
            .help(chooseHelp)
        }
        .font(.system(size: 12))
    }

    private func argumentField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField(LocalizedStringKey(placeholder), text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<RunOptions, String>) -> Binding<String> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { options[keyPath: keyPath] = $0 }
        )
    }

    private func projectToolchainBinding(
        _ keyPath: WritableKeyPath<ProjectToolchainSelection, String>
    ) -> Binding<String> {
        Binding(
            get: { projectToolchain[keyPath: keyPath] },
            set: { projectToolchain[keyPath: keyPath] = $0 }
        )
    }

    private func profileBinding(for profile: MavenProfile) -> Binding<Bool> {
        Binding(
            get: { options.activeProfiles.contains(profile.id) },
            set: { enabled in
                if enabled {
                    options.activeProfiles.insert(profile.id)
                } else {
                    options.activeProfiles.remove(profile.id)
                }
            }
        )
    }

    private func chooseDirectory(for keyPath: WritableKeyPath<RunOptions, String>) {
        presentPathPicker(.directory(keyPath))
    }

    private func chooseFileOrDirectory(for keyPath: WritableKeyPath<RunOptions, String>) {
        presentPathPicker(.fileOrDirectory(keyPath))
    }

    private func chooseProjectToolchainDirectory(
        for keyPath: WritableKeyPath<ProjectToolchainSelection, String>
    ) {
        presentPathPicker(.projectToolchainDirectory(keyPath))
    }

    private func chooseProjectToolchainFileOrDirectory(
        for keyPath: WritableKeyPath<ProjectToolchainSelection, String>
    ) {
        presentPathPicker(.projectToolchainFileOrDirectory(keyPath))
    }

    private func presentPathPicker(_ picker: PathPicker) {
        activePathPicker = picker
        isPathPickerPresented = true
    }

    private func selectPath(_ result: Result<URL, Error>) {
        defer { activePathPicker = nil }
        switch result {
        case .success(let url):
            guard let activePathPicker else { return }
            if saveScope == .project && !activePathPicker.isProjectToolchain {
                guard let projectURL = model.workspaceURL,
                      let path = projectRelativePath(url.path, root: projectURL) else {
                    saveError = String(localized: "Project paths must stay inside the current project.")
                    return
                }
                activePathPicker.assign(path, options: &options, projectToolchain: &projectToolchain)
            } else {
                activePathPicker.assign(url.path, options: &options, projectToolchain: &projectToolchain)
            }
            saveError = nil
        case .failure(let error):
            let cocoaError = error as NSError
            guard !(cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError) else { return }
            saveError = error.localizedDescription
        }
    }

    private func scopedOptionsForSave() -> RunOptions? {
        guard saveScope == .project else { return options }
        guard let projectURL = model.workspaceURL else {
            saveError = String(localized: "Open a project before choosing project paths.")
            return nil
        }
        var scopedOptions = options
        for keyPath in [
            \.javaHomePath,
            \.mavenExecutablePath,
            \.mavenJavaHomePath,
            \.workingDirectoryPath
        ] as [WritableKeyPath<RunOptions, String>] {
            let value = scopedOptions[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard let relativePath = projectRelativePath(value, root: projectURL) else {
                saveError = String(localized: "Project paths must stay inside the current project.")
                return nil
            }
            scopedOptions[keyPath: keyPath] = relativePath
        }
        return scopedOptions
    }

    private func projectRelativePath(_ path: String, root: URL) -> String? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard (expandedPath as NSString).isAbsolutePath else { return path }
        let rootPath = root.standardizedFileURL.path
        let selectedPath = URL(fileURLWithPath: expandedPath).standardizedFileURL.path
        if selectedPath == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard selectedPath.hasPrefix(prefix) else { return nil }
        return String(selectedPath.dropFirst(prefix.count))
    }

    private enum PathPicker {
        case directory(WritableKeyPath<RunOptions, String>)
        case fileOrDirectory(WritableKeyPath<RunOptions, String>)
        case projectToolchainDirectory(WritableKeyPath<ProjectToolchainSelection, String>)
        case projectToolchainFileOrDirectory(WritableKeyPath<ProjectToolchainSelection, String>)

        var allowedContentTypes: [UTType] {
            switch self {
            case .directory, .projectToolchainDirectory: [.folder]
            case .fileOrDirectory, .projectToolchainFileOrDirectory: [.item]
            }
        }

        var isProjectToolchain: Bool {
            switch self {
            case .directory, .fileOrDirectory: false
            case .projectToolchainDirectory, .projectToolchainFileOrDirectory: true
            }
        }

        func assign(
            _ path: String,
            options: inout RunOptions,
            projectToolchain: inout ProjectToolchainSelection
        ) {
            switch self {
            case .directory(let keyPath), .fileOrDirectory(let keyPath):
                options[keyPath: keyPath] = path
            case .projectToolchainDirectory(let keyPath), .projectToolchainFileOrDirectory(let keyPath):
                projectToolchain[keyPath: keyPath] = path
            }
        }
    }

    private static func configurationOverrides(
        _ options: RunOptions,
        defaults: ProjectToolchainSelection
    ) -> RunOptions {
        var overrides = options
        if overrides.javaHomePath == defaults.javaHomePath { overrides.javaHomePath = "" }
        if overrides.mavenExecutablePath == defaults.mavenExecutablePath { overrides.mavenExecutablePath = "" }
        if overrides.mavenJavaHomePath == defaults.mavenJavaHomePath { overrides.mavenJavaHomePath = "" }
        return overrides
    }

    private static func environmentText(from environment: [String: String]) -> String {
        environment.keys.sorted().map { key in
            key + "=" + (environment[key] ?? "")
        }.joined(separator: "\n")
    }

    private static func environment(from text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard let separator = value.firstIndex(of: "=") else { continue }
            let key = value[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = String(value[value.index(after: separator)...])
        }
        return result
    }
}

typealias JavaRunConfigurationEditorView = RunConfigurationEditorView
