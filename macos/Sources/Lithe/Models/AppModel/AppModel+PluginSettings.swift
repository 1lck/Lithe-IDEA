import Foundation
import LitheCoreContracts
import LitheExecutionModule
import LitheModuleAPI

// Note: 插件设置注册面与生效方式见 .agents/notes/implemented/architecture/2026-10-21-plugin-settings-surfaces.md

/// What became of a changed plugin setting, so the page can say whether
/// anything is still left for the user to do.
enum PluginSettingApplication: Equatable, Sendable {
    /// Running servers already use it, or none runs and the next start reads it.
    case applied
    /// A running language server reads it only when it starts again.
    case restartRequired
    /// The plugin's build models are loading again with it.
    case reloaded
    /// The next run or build picks it up.
    case nextRun
}

extension AppModel {
    /// Stores a plugin setting in one layer; `nil` restores the next layer's
    /// value. The setting's declared effect decides what happens next: an
    /// immediate setting reaches the plugin's running servers through
    /// `workspace/configuration`, a reload setting reloads its build models.
    @discardableResult
    func setPluginSetting(
        _ value: ToolingJSONValue?,
        id settingID: String,
        for pluginID: PluginID,
        layer: PluginSettingLayer = .global
    ) -> PluginSettingApplication? {
        let manager = services.pluginManager
        manager.settingsProjectRootURL = workspaceURL
        do {
            try manager.setSetting(value, id: settingID, for: pluginID, layer: layer)
        } catch {
            showNotification(error.localizedDescription)
            return nil
        }
        objectWillChange.send()
        let effect = manager.snapshots.first { $0.id == pluginID }?
            .settings.first { $0.id == settingID }?.declaration.effect ?? .restart
        return applyPluginSetting(effect, of: pluginID)
    }

    private func applyPluginSetting(
        _ effect: DeclarativePluginSetting.Effect,
        of pluginID: PluginID
    ) -> PluginSettingApplication {
        let running = languageToolingSessionsIfActive?.runningLanguageIDs(ofPlugin: pluginID.rawValue) ?? []
        switch effect {
        case .editorNavigation:
            return .applied
        case .immediate:
            guard let sessions = languageToolingSessionsIfActive else { return .applied }
            let updates = running.compactMap { languageID -> (String, ToolingJSONValue)? in
                guard let configuration = services.pluginManager.workspaceConfiguration(
                    forPlugin: pluginID, languageID: languageID
                ) else { return nil }
                return (languageID, configuration)
            }
            guard !updates.isEmpty else { return .applied }
            Task { @MainActor [weak self] in
                for (languageID, configuration) in updates {
                    switch await sessions.updateWorkspaceConfiguration(
                        configuration, languageID: languageID, pluginID: pluginID.rawValue
                    ) {
                    case .applied, .superseded:
                        continue
                    case .failed:
                        self?.showNotification(L10n.string("The language server could not apply this setting. Restart it to use the new value."))
                        return
                    }
                }
            }
            return .applied
        case .restart:
            return running.isEmpty ? .applied : .restartRequired
        case .reload:
            guard let feature = buildSystemsFeatureIfActive else { return .applied }
            for entry in feature.entries where entry.source.pluginID == pluginID.rawValue {
                feature.loadModel(entry.id, reason: .refresh)
            }
            return .reloaded
        case .nextRun:
            return .nextRun
        }
    }

    /// Runs a button a plugin put on a settings page: one of its own plugin
    /// functions, served by the plugin's provider process for this project.
    /// The host knows nothing about what the function does.
    func runPluginSettingAction(_ action: DeclarativePluginSettingAction, of pluginID: PluginID) async {
        guard let workspaceURL, let access = await activateExecutionModule(),
              let feature = access.buildSystems else {
            showNotification(settings.language.localizedString("native.inline.openAProjectThatUsesThisPluginFirst"))
            return
        }
        loadBuildSystems(access)
        do {
            _ = try await feature.prepareLanguageImport(workspaceURL: workspaceURL)
        } catch is CancellationError {
            return
        } catch {
            showNotification(error.localizedDescription)
            return
        }
        guard self.workspaceURL?.standardizedFileURL == workspaceURL.standardizedFileURL else { return }
        let candidates = feature.entries.filter { $0.source.pluginID == pluginID.rawValue }
        let preferred: BuildSystemEntry? = if case .buildSystem(let id) = action.page {
            candidates.first { $0.instance.buildSystemID == id }
        } else {
            nil
        }
        guard let entry = preferred ?? candidates.first else {
            showNotification(settings.language.localizedFormat("native.inline.arg1NeedsThisPluginSBuildSystemWhichThisProjectDoesNotUse", String(describing: action.title)))
            return
        }
        do {
            _ = try await feature.invokePluginFunction(
                entry.id, functionID: action.functionID, params: .object([:]), timeout: .seconds(600)
            ) { _ in }
            showNotification(settings.language.localizedFormat("native.inline.arg1Finished", String(describing: action.title)))
        } catch is CancellationError {
            return
        } catch {
            showNotification(error.localizedDescription)
        }
    }
}

extension AppModel {
    /// Wires a plugin settings surface to this project window.
    func pluginSettingsHandlers(for pluginID: PluginID) -> PluginSettingsHandlers {
        PluginSettingsHandlers(
            setValue: { [weak self] settingID, value, layer in
                self?.setPluginSetting(value, id: settingID, for: pluginID, layer: layer)
            },
            restartLanguageServers: { [weak self] in self?.restartLanguageServers() },
            runAction: { [weak self] action in await self?.runPluginSettingAction(action, of: pluginID) },
            choosePath: { [weak self] directory in
                guard let self else { return nil }
                let title = L10n.string("Choose")
                return directory
                    ? self.platformUI.chooseDirectory(title: title, prompt: title)
                    : self.platformUI.chooseFile(title: title, prompt: title)
            }
        )
    }
}


extension AppModel {
    /// Plugin declarations own opt-in; the editor only implements the generic gesture.
    func refreshPluginEditorNavigation() {
        let enabled = PluginSettingsRegistry.definitionNavigationLanguages(in: pluginSnapshots)
        guard enabled != definitionNavigationLanguages else { return }
        if !definitionNavigationLanguages.subtracting(enabled).isEmpty { closeLanguageNavigationResults() }
        definitionNavigationLanguages = enabled
    }

    func isDefinitionNavigationEnabled(for url: URL) -> Bool {
        guard let provider = languageProviderCatalog.provider(for: url) else { return false }
        return definitionNavigationLanguages.contains(provider.languageIdentifier(for: url))
    }
}
