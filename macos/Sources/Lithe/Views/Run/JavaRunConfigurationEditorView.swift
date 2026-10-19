import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct RunConfigurationEditorView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: RunFeatureModel
    let configuration: RunConfiguration
    let onClose: () -> Void
    @State private var options: RunOptions
    @State private var environmentText: String
    @State private var saveScope: RunConfigurationSaveScope = .local
    @State private var saveError: String?
    @State private var activePathPicker: PathPicker?
    @State private var isPathPickerPresented = false

    init(feature: RunFeatureModel, configuration: RunConfiguration, onClose: @escaping () -> Void) {
        self.feature = feature
        self.configuration = configuration
        self.onClose = onClose
        let initialOptions = feature.options(for: configuration)
        let projectToolchain = feature.projectToolchain
        _options = State(initialValue: Self.configurationOverrides(initialOptions, defaults: projectToolchain))
        _environmentText = State(initialValue: Self.environmentText(from: initialOptions.environment))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    saveScopeRow
                    configurationDetails
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
                .font(LitheTheme.settingsFont)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack(spacing: 10) {
                Button("Reset") {
                    options = RunOptions()
                    environmentText = ""
                }
                .buttonStyle(.litheNoPress)
                .lithePointer()
                .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                if let saveError {
                    Label {
                        Text(saveError).lineLimit(2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(LitheTheme.uiFont(size: 11))
                    .foregroundStyle(LitheTheme.error)
                    .frame(maxWidth: 280, alignment: .trailing)
                }
                Button("Cancel", action: onClose)
                    .buttonStyle(LitheSecondaryButtonStyle(horizontalPadding: 12, height: 28))
                Button("Save") {
                    options.environment = Self.environment(from: environmentText)
                    guard let scopedOptions = scopedOptionsForSave() else { return }
                    // The runtime settings mirror the project defaults and are
                    // their source until `.lithe/run/local.json` saves them.
                    if feature.saveEditorChanges(
                        scopedOptions,
                        toolchain: model.runtimeFeature.projectToolchainSelection,
                        for: configuration,
                        scope: saveScope
                    ) {
                        onClose()
                    } else {
                        saveError = feature.configurationSaveError
                    }
                }
                    .buttonStyle(LithePrimaryButtonStyle(horizontalPadding: 14, height: 28))
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(LitheTheme.toolHeader)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LitheTheme.window)
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

    private var saveScopeInfo: LocalizedStringKey {
        saveScope == .local
            ? "Saved in .lithe/run/local.json and excluded from Git."
            : "Saved in .lithe/run/configurations.json for the whole team. Local JDK paths are never shared."
    }

    private var saveScopeRow: some View {
        HStack(spacing: 12) {
            LitheSettingsLabel("Save scope", info: saveScopeInfo)
            Spacer(minLength: 16)
            LitheSettingsSegmentedControl(
                selection: $saveScope,
                options: [.local, .project],
                width: 200
            ) { scope in
                switch scope {
                case .local: "This Mac"
                case .project: "Project"
                }
            }
        }
        .frame(minHeight: 28)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LitheTheme.accent.opacity(0.12))
                .frame(width: 30, height: 30)
                .overlay {
                    RunConfigurationIcon(kind: configuration.kind, size: 17)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Run Configuration")
                        .font(LitheTheme.uiFont(size: 14, weight: .semibold))
                    typeBadge
                    sourceBadge
                }
                Text(configuration.name)
                    .font(LitheTheme.uiFont(size: 11.5))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(configuration.name)
            }

            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(LitheTheme.uiFont(size: 11, weight: .semibold))
            }
            .litheIconButton()
            .help("Close run configuration")
        }
        .foregroundStyle(LitheTheme.primaryText)
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(LitheTheme.toolHeader)
    }

    private var typeBadge: some View {
        HStack(spacing: 5) {
            RunConfigurationIcon(kind: configuration.kind, size: 11)
            Text(LocalizedStringKey(configuration.kind.title))
                .lineLimit(1)
        }
        .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
        .foregroundStyle(LitheTheme.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(LitheTheme.accent.opacity(0.10))
        .clipShape(Capsule())
    }

    private var sourceBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: sourceSymbol)
                .font(LitheTheme.uiFont(size: 9, weight: .semibold))
            Text(sourceTitle)
                .lineLimit(1)
        }
        .font(LitheTheme.uiFont(size: 10.5, weight: .medium))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(LitheTheme.settingsControlBackground)
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(LitheTheme.settingsControlBorder, lineWidth: 1)
        }
    }

    private var sourceSymbol: String {
        switch feature.source(for: configuration) {
        case .generated: "sparkles"
        case .project: "person.2"
        case .local: "desktopcomputer"
        }
    }

    @ViewBuilder private var configurationDetails: some View {
        if configuration.mainClass != nil || configuration.modulePath != nil {
            section(title: "Configuration details") {
                if let mainClass = configuration.mainClass {
                    summaryRow(title: "Main class", value: mainClass, isCode: true)
                }
                if let modulePath = configuration.modulePath {
                    summaryRow(title: "Maven module", value: modulePath)
                }
            }
        }
    }

    private var sourceTitle: String {
        switch feature.source(for: configuration) {
        case .generated: String(localized: "Automatically generated")
        case .project: String(localized: "Project configuration")
        case .local: String(localized: "This Mac")
        }
    }

    private var runtimeSection: some View {
        section(
            title: "Configuration overrides",
            info: "These overrides affect only this run configuration. Clear a path to inherit the project environment."
        ) {
            if effectiveCapabilities.contains(.javaRuntime) {
                pathRow(
                    title: "JDK Home",
                    placeholder: "Use project default",
                    text: stringBinding(\.javaHomePath),
                    chooseDirectory: { chooseDirectory(for: \.javaHomePath) }
                )
                EffectiveRuntimeLabel(
                    feature: model.runtimeFeature,
                    choice: { model.runtimeFeature.javaChoice(overridePath: nonEmpty(options.javaHomePath)) },
                    kind: .java,
                    mode: options.javaHomePath.isEmpty ? .inherited : .configured,
                    requirements: requirementMessages(for: "project-jdk")
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
                if let workspaceURL = model.workspaceURL {
                    EffectiveRuntimeLabel(
                        feature: model.runtimeFeature,
                        choice: {
                            model.runtimeFeature.mavenChoice(
                                at: workspaceURL,
                                overridePath: nonEmpty(options.mavenExecutablePath)
                                    ?? model.runtimeFeature.settings.mavenExecutableOverride
                            )
                        },
                        kind: .maven,
                        mode: options.mavenExecutablePath.isEmpty ? .inherited : .configured,
                        requirements: requirementMessages(for: "project-maven")
                    )
                }
                pathRow(
                    title: "Maven JDK Home",
                    placeholder: "Use project default",
                    text: stringBinding(\.mavenJavaHomePath),
                    chooseDirectory: { chooseDirectory(for: \.mavenJavaHomePath) }
                )
                EffectiveRuntimeLabel(
                    feature: model.runtimeFeature,
                    choice: { model.runtimeFeature.mavenJavaChoice(overridePath: effectiveMavenJavaOverride) },
                    kind: .java,
                    mode: options.mavenJavaHomePath.isEmpty ? .inherited : .configured
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

    private func nonEmpty(_ path: String) -> String? {
        path.isEmpty ? nil : path
    }

    /// Mirrors the Maven toolchain provider: Core fills empty overrides with the
    /// project defaults, and an empty Maven JDK then uses this configuration's JDK.
    private var effectiveMavenJavaOverride: String? {
        let defaults = model.runtimeFeature.settings
        let mavenJDK = nonEmpty(options.mavenJavaHomePath) ?? nonEmpty(defaults.mavenJavaHomePath)
        return mavenJDK ?? nonEmpty(options.javaHomePath) ?? nonEmpty(defaults.javaHomePath)
    }

    private func requirementMessages(for toolchain: String) -> [String] {
        feature.configurationDiagnostics.toolchainRequirementMessages(
            for: toolchain,
            configurationID: configuration.id
        )
    }

    private var projectToolchainSection: some View {
        section(
            title: "Project environment",
            info: "Run configurations inherit the project JDK and Maven unless overridden below."
        ) {
            Button {
                onClose()
                model.showSettings(category: .project)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(LitheTheme.uiFont(size: 12))
                        .foregroundStyle(LitheTheme.accent)
                    Text("Configure project JDK and Maven…")
                        .foregroundStyle(LitheTheme.primaryText)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(LitheTheme.uiFont(size: 9, weight: .semibold))
                        .foregroundStyle(LitheTheme.tertiaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
                .litheSettingsControlChrome()
            }
            .buttonStyle(.litheNoPress)
            .lithePointer()
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
        section(title: "Environment", info: "One NAME=value entry per line") {
            TextEditor(text: $environmentText)
                .litheSettingsTextEditor(height: 88)
        }
    }

    private var mavenOptionsSection: some View {
        section(title: "Maven") {
            if effectiveCapabilities.contains(.mavenSkipTests) {
                HStack(spacing: 12) {
                    LitheSettingsLabel("Tests")
                    Spacer(minLength: 16)
                    LitheSettingsSegmentedControl(
                        selection: Binding(
                            get: { options.mavenSkipTests },
                            set: { options.mavenSkipTests = $0 }
                        ),
                        options: [nil, false, true],
                        width: 300
                    ) { value in
                        switch value {
                        case nil: "Project default"
                        case false: "Run tests"
                        case true: "Skip tests"
                        }
                    }
                }
                .frame(minHeight: 28)
            }
            if effectiveCapabilities.contains(.mavenProfiles) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(feature.mavenProfiles) { profile in
                        LitheSettingsCheckbox(
                            isOn: profileBinding(for: profile),
                            title: LocalizedStringKey(profile.id)
                        )
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        title: String,
        info: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LitheSettingsSection(title: title, accessory: {
            if let info {
                LitheInfoTip(info)
            }
        }, content: content)
    }

    private func summaryRow(title: String, value: String, isCode: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(LitheTheme.secondaryText)
                .frame(width: 100, alignment: .leading)
            Text(verbatim: value)
                .font(isCode
                    ? LitheTheme.uiFont(size: 11.5, design: .monospaced)
                    : LitheTheme.settingsFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 0)
        }
        .font(LitheTheme.settingsFont)
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
                .litheSettingsTextField()
            Button(action: chooseDirectory) {
                LitheSystemIcon(systemImage: "folder")
            }
            .litheIconButton()
            .help(chooseHelp)
        }
        .font(LitheTheme.settingsFont)
    }

    private func argumentField(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(title))
                .font(LitheTheme.uiFont(size: 11.5))
                .foregroundStyle(LitheTheme.secondaryText)
            TextField(LocalizedStringKey(placeholder), text: text)
                .litheSettingsTextField()
        }
    }

    private func stringBinding(_ keyPath: WritableKeyPath<RunOptions, String>) -> Binding<String> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { options[keyPath: keyPath] = $0 }
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


    private func presentPathPicker(_ picker: PathPicker) {
        activePathPicker = picker
        isPathPickerPresented = true
    }

    private func selectPath(_ result: Result<URL, Error>) {
        defer { activePathPicker = nil }
        switch result {
        case .success(let url):
            guard let activePathPicker else { return }
            if saveScope == .project {
                guard let projectURL = model.workspaceURL,
                      let path = projectRelativePath(url.path, root: projectURL) else {
                    saveError = String(localized: "Project paths must stay inside the current project.")
                    return
                }
                activePathPicker.assign(path, options: &options)
            } else {
                activePathPicker.assign(url.path, options: &options)
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

        var allowedContentTypes: [UTType] {
            switch self {
            case .directory: [.folder]
            case .fileOrDirectory: [.item]
            }
        }

        func assign(
            _ path: String,
            options: inout RunOptions
        ) {
            switch self {
            case .directory(let keyPath), .fileOrDirectory(let keyPath):
                options[keyPath: keyPath] = path
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
