import LitheModuleAPI
import SwiftUI

/// Where tools come from on this computer: the login-shell read and the plugin-declared version managers.
struct ToolchainSourcesSettingsView: View {
    @ObservedObject var feature: ToolchainSettingsFeatureModel
    var onOpenPlugins: () -> Void
    @State private var showsPath = false
    @State private var expandedProviderIDs = Set<String>()
    @State private var rereadTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ToolchainSettingsSnapshotNotice(feature: feature)
                if feature.loginShell?.pathChangedSinceLaunch == true {
                    LitheSettingsNotice("The login shell's PATH has changed. Restart Lithe so that terminals and tools use it.") {
                        RestartLitheButton(prominent: false)
                    }
                }
                if let shell = feature.loginShell {
                    loginShellGroup(shell)
                }
                providersGroup
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(LitheTheme.settingsPage)
        .clipped()
        .onDisappear { rereadTask?.cancel(); rereadTask = nil }
    }

    // MARK: Login shell

    private func loginShellGroup(_ shell: LoginShellEnvironmentSnapshot) -> some View {
        ToolchainSettingsGroup(Text("Login shell"), accessory: {
            LitheInfoTip("At launch Lithe reads your login shell's environment, as a terminal does, and gives it to the terminals, tools and language servers it starts. Only PATH is listed; other variables can hold secrets and are only counted.")
        }) {
            ToolchainSettingsLine("Shell") {
                if shell.shell.isEmpty {
                    Text("Not found").foregroundStyle(LitheTheme.tertiaryText)
                } else {
                    LitheSettingsPill(verbatim: shell.shell, kind: .value)
                }
            }
            ToolchainSettingsLine("Read result") {
                readResult(shell)
                if shell.state != .disabled, shell.state != .reading, !shell.shell.isEmpty {
                    Button("Read again") {
                        rereadTask?.cancel()
                        rereadTask = Task { await feature.rereadLoginShell() }
                    }
                    .buttonStyle(.litheNoPress)
                    .foregroundStyle(LitheTheme.accent)
                    .disabled(feature.isRereadingLoginShell)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolchain-login-shell-read")
            ToolchainSettingsLine(verbatim: "PATH", info: "Directories in the order tools are looked up. The login shell's directories come first, then any that only the environment Lithe was launched with had.") {
                Text("\(shell.processPath.count) directories")
                    .foregroundStyle(LitheTheme.secondaryText)
                if !shell.processPath.isEmpty {
                    Button { showsPath.toggle() } label: { showsPath ? Text("Show less") : Text("Show") }
                        .buttonStyle(.litheNoPress)
                        .foregroundStyle(LitheTheme.accent)
                }
            }
            if showsPath, !shell.processPath.isEmpty {
                pathList(shell.processPath)
            }
        }
    }

    @ViewBuilder private func readResult(_ shell: LoginShellEnvironmentSnapshot) -> some View {
        switch shell.state {
        case .disabled:
            Text("Turned off by LITHE_SKIP_SHELL_ENV")
                .foregroundStyle(LitheTheme.secondaryText)
        case .reading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading…").foregroundStyle(LitheTheme.secondaryText)
            }
        case .notRead:
            (shell.startedFromCache ? Text("Not read yet; started with the PATH saved last time") : Text("Not read yet"))
                .foregroundStyle(LitheTheme.tertiaryText)
        case .failed:
            HStack(spacing: 6) {
                LitheSettingsPill("Failed", kind: .effect)
                (shell.startedFromCache ? Text("Using the PATH saved last time") : Text("Using the environment Lithe was launched with"))
                    .foregroundStyle(LitheTheme.secondaryText)
                    .lineLimit(1)
            }
        case .read:
            HStack(spacing: 5) {
                if let count = shell.variableCount {
                    Text("\(count) variables")
                }
                if let milliseconds = shell.durationMilliseconds {
                    Text(verbatim: "·").foregroundStyle(LitheTheme.tertiaryText)
                    Text("\(milliseconds) ms")
                }
                if let date = shell.readAt {
                    Text(verbatim: "·").foregroundStyle(LitheTheme.tertiaryText)
                    Text(date, style: .time)
                }
            }
            .foregroundStyle(LitheTheme.secondaryText)
            .lineLimit(1)
        }
    }

    private func pathList(_ entries: [LoginShellEnvironmentSnapshot.PathEntry]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 8) {
                    Text(verbatim: String(index + 1))
                        .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                        .foregroundStyle(LitheTheme.tertiaryText)
                        .frame(width: 20, alignment: .trailing)
                    Text(verbatim: ToolchainSettingsText.abbreviated(entry.path))
                        .font(LitheTheme.uiFont(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(entry.path)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    if entry.origin == .inherited {
                        ToolchainSettingsTag("Launch environment")
                    }
                }
                .frame(minHeight: 20)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-login-shell-path")
    }

    // MARK: Version managers

    private var providersGroup: some View {
        let providers = feature.providers
        return ToolchainSettingsGroup(Text("Version managers"), accessory: {
            LitheInfoTip("Version managers come from enabled plugins. Lithe looks for the files they watch in this project; it does not run or query them yet.")
        }) {
            if providers.isEmpty {
                HStack(spacing: 10) {
                    Text("No enabled plugin provides a version manager.")
                        .foregroundStyle(LitheTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Open Plugins", action: onOpenPlugins).buttonStyle(LitheActionButtonStyle())
                }
                .font(LitheTheme.uiFont(size: 12))
                .frame(minHeight: 36)
            } else {
                ForEach(providers) { provider in
                    providerRow(provider)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolchain-providers-section")
    }

    private func providerRow(_ provider: ToolchainSettingsSnapshot.Provider) -> some View {
        let isExpanded = expandedProviderIDs.contains(provider.id)
        let found = foundFiles(provider)
        let hasWorkspace = feature.snapshot?.workspaceURL != nil
        return VStack(alignment: .leading, spacing: 0) {
            ToolchainEdgeLayout(minimumLeadingWidth: 220, trailingIndent: 26) {
                HStack(spacing: 6) {
                    Button {
                        if isExpanded { expandedProviderIDs.remove(provider.id) } else { expandedProviderIDs.insert(provider.id) }
                    } label: {
                        HStack(spacing: 6) {
                            LitheTreeDisclosureIcon(isExpanded: isExpanded)
                            ToolchainSettingsIcon(name: provider.title, key: provider.id, token: nil)
                            Text(verbatim: provider.title)
                                .font(LitheTheme.uiFont(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.litheNoPress)
                    .accessibilityLabel(Text(verbatim: provider.title))
                    .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
                    ForEach(toolNames(provider), id: \.self) { ToolchainSettingsTag(verbatim: $0) }
                }
                if hasWorkspace {
                    if found.isEmpty {
                        Text("Not used in this project")
                            .font(LitheTheme.uiFont(size: 11.5))
                            .foregroundStyle(LitheTheme.tertiaryText)
                    } else {
                        LitheSettingsPill("\(found.count) version files", kind: .project)
                    }
                }
            }
            .frame(minHeight: 32)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("toolchain-provider:" + provider.id)
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ToolchainSettingsMetaLine("Watched files") {
                        if provider.watchFiles.isEmpty {
                            Text("None").foregroundStyle(LitheTheme.tertiaryText)
                        }
                        ForEach(provider.watchFiles, id: \.self) { ToolchainSettingsTag(verbatim: $0, kind: .value) }
                    }
                    if hasWorkspace {
                        ToolchainSettingsMetaLine("This project") {
                            if found.isEmpty {
                                Text("None").foregroundStyle(LitheTheme.tertiaryText)
                            }
                            ForEach(found, id: \.self) { path in
                                Text(verbatim: path)
                                    .font(LitheTheme.uiFont(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    ToolchainSettingsMetaLine("Definition", info: "This version manager comes from an enabled plugin. Lithe has no built-in version managers.") {
                        LitheSettingsPill(verbatim: provider.pluginName, wraps: true)
                        Text(verbatim: provider.id)
                            .font(LitheTheme.uiFont(size: 10.5, design: .monospaced))
                            .foregroundStyle(LitheTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Open Plugins", action: onOpenPlugins)
                            .buttonStyle(.litheNoPress)
                            .foregroundStyle(LitheTheme.accent)
                    }
                }
                .padding(.leading, 26)
                .padding(.bottom, 6)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    /// Workspace-relative version files this provider watches that exist in the listed directories.
    private func foundFiles(_ provider: ToolchainSettingsSnapshot.Provider) -> [String] {
        (feature.snapshot?.directories ?? []).flatMap { directory in
            directory.versionFiles.filter { $0.providerIDs.contains(provider.id) }.map(\.path)
        }
    }

    private func toolNames(_ provider: ToolchainSettingsSnapshot.Provider) -> [String] {
        let tools = feature.snapshot?.tools ?? []
        return provider.tools.map { id in tools.first { $0.id == id }?.displayName ?? id }
    }
}
