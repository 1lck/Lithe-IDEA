import LitheCoreContracts
import LitheModuleAPI
import SwiftUI

// Note: 插件设置注册面与生效方式见 .agents/notes/implemented/architecture/2026-10-21-plugin-settings-surfaces.md

/// A sidebar page that plugins registered. The layout is the same for every
/// language and build system: a status card for a language the plugins
/// serve with a language server, then each plugin's options and buttons
/// under its name. Nothing here depends on which language, build system,
/// or plugin it is.
struct ContributedSettingsPageView: View {
    @EnvironmentObject private var settingsContext: SettingsModelContext
    private var model: AppModel { settingsContext.model }
    let page: ContributedSettingsPage
    let openPlugin: (PluginID) -> Void
    @State private var layer = PluginSettingLayer.project

    private var hasProjectSettings: Bool {
        model.workspaceURL != nil
            && page.contributions.contains { $0.settings.contains { $0.declaration.scope == .project } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LitheSettingsBanner {
                    Text(LocalizedStringKey("Provided by"))
                    ForEach(page.contributions) { contribution in
                        Button { openPlugin(contribution.pluginID) } label: {
                            LitheSettingsPill(verbatim: contribution.pluginName, kind: .value)
                        }
                        .buttonStyle(.litheNoPress)
                        .help(Text(LocalizedStringKey("Plugin Details")))
                    }
                    Spacer(minLength: 8)
                    if hasProjectSettings {
                        Text(LocalizedStringKey("Changes are written to"))
                        PluginSettingLayerPicker(layer: $layer)
                    }
                }
                if let languageID = page.languageID,
                   page.contributions.contains(where: \.providesLanguageServer) {
                    ContributedLanguageStatusSection(languageID: languageID, title: page.title)
                }
                ForEach(page.contributions) { contribution in
                    if contribution.settings.isEmpty && contribution.actions.isEmpty {
                        LitheSettingsSection(contribution.pluginName) {
                            Text(LocalizedStringKey("This plugin adds no options to this page."))
                                .foregroundStyle(LitheTheme.tertiaryText)
                        }
                    } else {
                        PluginSettingsSection(
                            settings: contribution.settings,
                            actions: contribution.actions,
                            hasProject: model.workspaceURL != nil,
                            handlers: model.pluginSettingsHandlers(for: contribution.pluginID),
                            title: contribution.pluginName,
                            layer: $layer
                        )
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .litheScrollViewChrome(alwaysShowVertical: true, usesCompactScrollers: true)
    }
}

/// The language service of one language in this project: its state, the
/// per-project switch, and a restart. The same card serves every language.
private struct ContributedLanguageStatusSection: View {
    @EnvironmentObject private var model: AppModel
    let languageID: String
    let title: String

    private var descriptor: LanguageProviderDescriptor? {
        model.languageProviderCatalog.descriptors.first { $0.id == languageID }
    }

    var body: some View {
        let isEnabled = !model.isLanguageServerDisabledInCurrentWorkspace(providerID: languageID)
        let status = LSPControlCenterPresenter.serverStatus(
            isDisabled: !isEnabled,
            sessionState: model.languageToolingSessionsIfActive?.languageServerStates[languageID]
        )
        let info = model.languageToolingSessionsIfActive?.languageServerInfos[languageID]
        LitheSettingsSection(title: "Language Service", accessory: {
            if model.workspaceURL != nil, descriptor != nil {
                Spacer(minLength: 0)
                Button(LocalizedStringKey("Restart Language Servers")) { model.restartLanguageServers() }
                    .buttonStyle(LitheActionButtonStyle())
                    .disabled(!isEnabled)
            }
        }) {
            LitheSettingsRow(LocalizedStringKey("Status")) {
                Circle().fill(color(status)).frame(width: 7, height: 7)
                Text(LocalizedStringKey(description(status)))
                    .foregroundStyle(status == .error ? LitheTheme.error : LitheTheme.secondaryText)
            } badges: {
                if let info {
                    LitheSettingsPill(
                        verbatim: [info.name, info.version].compactMap { $0 }.joined(separator: " "),
                        kind: .value
                    )
                }
            }
            if model.workspaceURL != nil, descriptor != nil {
                LitheSettingsRow(LocalizedStringKey("Enable for this project")) {
                    Toggle("", isOn: Binding(
                        get: { isEnabled },
                        set: { model.setLanguageServerEnabled($0, providerID: languageID) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(Text(LocalizedStringKey("Language service for this project")))
                } badges: {
                    LitheSettingsPill(LocalizedStringKey("This project"), kind: .project)
                }
            }
        }
    }

    private func description(_ status: LSPServerStatus) -> String {
        if model.workspaceURL == nil { return "Open a project to see its language service." }
        return switch status {
        case .starting: "Starting"
        case .initializing: "Initializing project index"
        case .active: "Running"
        case .stopping: "Stopping"
        case .disabled: "Off for this project"
        case .stopped: "Starts on demand when a matching file is opened"
        case .error: "Failed to start; check the language server configuration"
        }
    }

    private func color(_ status: LSPServerStatus) -> Color {
        switch status {
        case .starting, .initializing: LitheTheme.accent
        case .active: LitheTheme.success
        case .stopping: LitheTheme.warning
        case .stopped, .disabled: LitheTheme.secondaryText
        case .error: LitheTheme.error
        }
    }
}
