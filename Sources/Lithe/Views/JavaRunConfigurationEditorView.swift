import AppKit
import SwiftUI

struct JavaRunConfigurationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: JavaRunService
    let configuration: JavaRunConfiguration
    @State private var options: JavaRunOptions

    init(service: JavaRunService, configuration: JavaRunConfiguration) {
        self.service = service
        self.configuration = configuration
        _options = State(initialValue: service.options(for: configuration))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(LitheTheme.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    configurationSummary
                    runtimeSection
                    argumentsSection
                    if configuration.kind != .currentFile && !service.mavenProfiles.isEmpty {
                        profilesSection
                    }
                }
                .padding(18)
            }

            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            HStack {
                Button("Reset") {
                    service.resetOptions(for: configuration)
                    options = service.options(for: configuration)
                }
                .buttonStyle(.borderless)
                .lithePointer()
                .foregroundStyle(LitheTheme.secondaryText)
                Spacer()
                Button("Done") { dismiss() }
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
        .onChange(of: options) {
            service.updateOptions(options, for: configuration)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: configuration.systemImage)
                .foregroundStyle(LitheTheme.accent)
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
            if let mainClass = configuration.mainClass {
                summaryRow(title: "Main class", value: mainClass)
            }
            if let modulePath = configuration.modulePath {
                summaryRow(title: "Maven module", value: modulePath)
            }
        }
    }

    private var runtimeSection: some View {
        section(title: "Runtime") {
            pathRow(
                title: "JDK Home",
                placeholder: "Use project JDK or system default",
                text: stringBinding(\.javaHomePath),
                chooseDirectory: { chooseDirectory(for: \.javaHomePath) }
            )
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
            argumentField(
                title: "VM options",
                placeholder: "-Xmx1g -Dserver.port=8080",
                text: stringBinding(\.vmArguments)
            )
            argumentField(
                title: "Program arguments",
                placeholder: "--spring.profiles.active=dev",
                text: stringBinding(\.programArguments)
            )
        }
    }

    private var profilesSection: some View {
        section(title: "Active Maven Profiles") {
            ForEach(service.mavenProfiles) { profile in
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

    private func stringBinding(_ keyPath: WritableKeyPath<JavaRunOptions, String>) -> Binding<String> {
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

    private func chooseDirectory(for keyPath: WritableKeyPath<JavaRunOptions, String>) {
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
}
