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
        case .immediate:
            guard let sessions = languageToolingSessionsIfActive else { return .applied }
            for languageID in running {
                guard let configuration = services.pluginManager.workspaceConfiguration(
                    forPlugin: pluginID, languageID: languageID
                ) else { continue }
                if !sessions.updateWorkspaceConfiguration(
                    configuration, languageID: languageID, pluginID: pluginID.rawValue
                ) {
                    return .restartRequired
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
        let chinese = settings.language == .simplifiedChinese
        guard workspaceURL != nil, let access = await activateExecutionModule(),
              let feature = access.buildSystems else {
            showNotification(chinese ? "请先打开使用该插件的项目" : "Open a project that uses this plugin first.")
            return
        }
        loadBuildSystems(access)
        let candidates = feature.entries.filter { $0.source.pluginID == pluginID.rawValue }
        let preferred: BuildSystemEntry? = if case .buildSystem(let id) = action.page {
            candidates.first { $0.instance.buildSystemID == id }
        } else {
            nil
        }
        guard let entry = preferred ?? candidates.first else {
            showNotification(chinese
                ? "“\(action.title)”需要该插件的构建系统，当前项目中没有找到"
                : "\u{201C}\(action.title)\u{201D} needs this plugin's build system, which this project does not use.")
            return
        }
        do {
            _ = try await feature.invokePluginFunction(
                entry.id, functionID: action.functionID, params: .object([:]), timeout: .seconds(600)
            ) { _ in }
            showNotification(chinese ? "“\(action.title)”已完成" : "\u{201C}\(action.title)\u{201D} finished")
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
                let title = String(localized: "Choose")
                return directory
                    ? self.platformUI.chooseDirectory(title: title, prompt: title)
                    : self.platformUI.chooseFile(title: title, prompt: title)
            }
        )
    }
}
