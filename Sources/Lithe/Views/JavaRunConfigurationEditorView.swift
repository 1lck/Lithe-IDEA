import AppKit
import SwiftUI

struct RunConfigurationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @ObservedObject var feature: RunFeatureModel
    let configuration: RunConfiguration
    @State private var options: RunOptions
    @State private var environmentText: String
    @State private var saveScope: RunConfigurationSaveScope = .local
    @State private var saveError: String?

    init(feature: RunFeatureModel, configuration: RunConfiguration) {
        self.feature = feature
        self.configuration = configuration
        let initialOptions = feature.options(for: configuration)
        _options = State(initialValue: initialOptions)
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
                    runtimeSection
                    argumentsSection
                    if effectiveCapabilities.contains(.environment) {
                        environmentSection
                    }
                    if effectiveCapabilities.contains(.mavenProfiles) && !feature.mavenProfiles.isEmpty {
                        profilesSection
                    }
                }
                .padding(18)
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Button("Reset") {
                    options = RunOptions()
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
                    if feature.updateOptions(options, for: configuration, scope: saveScope) {
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
        section(title: "Runtime") {
            if effectiveCapabilities.contains(.javaRuntime) {
                pathRow(
                    title: "JDK Home",
                    placeholder: "Use project JDK or system default",
                    text: stringBinding(\.javaHomePath),
                    chooseDirectory: { chooseDirectory(for: \.javaHomePath) }
                )
                .disabled(saveScope == .project)
            }
            pathRow(
                title: "Working directory",
                placeholder: "Use project or file directory",
                text: stringBinding(\.workingDirectoryPath),
                chooseDirectory: { chooseDirectory(for: \.workingDirectoryPath) }
            )
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
                .background(LitheTheme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(LitheTheme.divider, lineWidth: 1)
                }
            Text("One NAME=value entry per line")
                .font(.system(size: 10.5))
                .foregroundStyle(LitheTheme.secondaryText)
        }
    }

    private var profilesSection: some View {
        section(title: "Active Maven Profiles") {
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
        chooseDirectory: @escaping () -> Void
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
            .help("Choose directory")
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
        let panel = NSOpenPanel()
        panel.title = "Choose Directory"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            options[keyPath: keyPath] = url.path
        }
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
