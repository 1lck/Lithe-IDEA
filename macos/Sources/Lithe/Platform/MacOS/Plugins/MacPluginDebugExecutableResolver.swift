import Foundation
import LitheCoreContracts

// Note: 调试适配器的可执行文件设置与默认发现见 .agents/notes/implemented/feature/2026-10-26-debug-adapter-executable-setting.md

/// Looks up the program a debug launch runs. Rust Core decides what to look
/// at (the user's setting first, then the plugin's candidates, in order); the
/// file system is the host's, so this is where the answer is checked.
struct MacPluginDebugExecutableResolver {
    private let planner: any DeclarativeLanguageServerLaunchPlanning
    private let settings: any PluginSettingsStoring
    private let isRunnable: @Sendable (String) -> Bool

    init(
        planner: any DeclarativeLanguageServerLaunchPlanning,
        settings: any PluginSettingsStoring,
        isRunnable: @escaping @Sendable (String) -> Bool = Self.isRunnableFile
    ) {
        self.planner = planner
        self.settings = settings
        self.isRunnable = isRunnable
    }

    /// A regular file the current user may execute; a directory such as an
    /// `.app` bundle is not a program a debugger can launch.
    static func isRunnableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// The program a launch runs; nil when the adapter declares no lookup. A
    /// missing program is an error the user can act on, never an empty launch.
    func executableForLaunch(
        plugin: InstalledPluginPackage,
        adapter: DeclarativeDebugAdapter,
        workspaceRootURL: URL,
        targetPath: String
    ) throws -> String? {
        guard let settingID = adapter.launchExecutableSettingID,
              let found = try lookup(
                plugin: plugin,
                adapterID: adapter.id,
                workspaceRootURL: workspaceRootURL,
                targetPath: targetPath
              )
        else { return nil }
        let pluginName = plugin.manifest.displayName
        let settingTitle = plugin.descriptor.settings.first { $0.id == settingID }?.title ?? settingID
        switch found {
        case .found(let path, _):
            return path
        case .configuredUnusable(let path):
            throw DebugLaunchConfigurationResolutionError.configuredExecutableUnusable(
                plugin: pluginName, setting: settingTitle, path: path
            )
        case .notFound(let searched):
            throw DebugLaunchConfigurationResolutionError.executableNotFound(
                plugin: pluginName, setting: settingTitle, searched: searched
            )
        }
    }

    /// Nil when the adapter declares no executable lookup. `targetPath` is the
    /// file being debugged; without one, candidates built from it are skipped.
    func lookup(
        plugin: InstalledPluginPackage,
        adapterID: String,
        workspaceRootURL: URL?,
        targetPath: String?
    ) throws -> DebugExecutableLookup? {
        let pluginID = plugin.manifest.id.rawValue
        let projectValues = workspaceRootURL.map {
            settings.projectValues(forPlugin: pluginID, projectRoot: $0)
        } ?? [:]
        guard let plan = try planner.debugExecutablePlan(
            manifest: plugin.descriptor.normalizedManifest,
            adapterID: adapterID,
            settings: settings.values(forPlugin: pluginID),
            projectSettings: projectValues,
            workspace: workspaceRootURL?.standardizedFileURL.path,
            targetPath: targetPath
        ) else { return nil }
        if let configured = plan.configured {
            return isRunnable(configured.path)
                ? .found(path: configured.path, isConfigured: true)
                : .configuredUnusable(path: configured.path)
        }
        if let found = plan.candidates.first(where: isRunnable) {
            return .found(path: found, isConfigured: false)
        }
        return .notFound(searched: plan.candidates)
    }
}
