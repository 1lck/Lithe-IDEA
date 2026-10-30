import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// What the host found for the program a plugin's debug adapter launches.
enum DebugExecutableLookup: Equatable, Sendable {
    /// A runnable program. `isConfigured` is true when the user chose it in
    /// the plugin's settings and false when the host discovered it.
    case found(path: String, isConfigured: Bool)
    /// The user chose a program that is not there or cannot run. Falling
    /// back to a discovered one would debug something the user did not pick.
    case configuredUnusable(path: String)
    /// Nothing is configured and none of the plugin's candidates is runnable.
    case notFound(searched: [String])
}

/// A plugin setting together with the value the next launch will use and
/// the stored layers it came from.
struct PluginSettingState: Equatable, Sendable, Identifiable {
    let declaration: DeclarativePluginSetting
    let value: ToolingJSONValue
    /// The layer `value` came from.
    var source: PluginSettingSource = .default
    /// The value stored for every project, if any.
    var globalValue: ToolingJSONValue? = nil
    /// The open project's override; only project-scoped settings have one.
    var projectValue: ToolingJSONValue? = nil
    /// What the host found for a setting that names a program the plugin runs;
    /// nil for every other setting. Shown beside the value, never stored.
    var discovery: DebugExecutableLookup? = nil

    var id: String { declaration.id }
    var isDefault: Bool { value == declaration.defaultValue }

    /// Merges the layers as Rust Core does for a launch: a project value
    /// (project scope only), then the global value, then the default. A
    /// stored value the declaration no longer accepts is skipped.
    static func resolve(
        _ declaration: DeclarativePluginSetting,
        global: ToolingJSONValue?,
        project: ToolingJSONValue?
    ) -> PluginSettingState {
        let project = declaration.scope == .project ? project.flatMap { declaration.accepts($0) ? $0 : nil } : nil
        let global = global.flatMap { declaration.accepts($0) ? $0 : nil }
        let (value, source): (ToolingJSONValue, PluginSettingSource) = if let project {
            (project, .project)
        } else if let global {
            (global, .global)
        } else {
            (declaration.defaultValue, .default)
        }
        return PluginSettingState(
            declaration: declaration,
            value: value,
            source: source,
            globalValue: global,
            projectValue: project
        )
    }
}

/// Which stored layer a settings change writes.
enum PluginSettingLayer: Equatable, Sendable {
    case global
    case project
}

/// Where a plugin contributes something to a settings page, so the
/// settings window can build pages from plugin declarations alone.
struct PluginSettingsContributions: Equatable, Sendable {
    struct BuildSystem: Equatable, Sendable {
        let id: String
        let displayName: String
        var nativeConfiguration = false
    }

    var languages: [DeclarativePluginLanguage] = []
    /// Languages the plugin's own language servers serve.
    var languageServerIDs: [String] = []
    var buildSystems: [BuildSystem] = []
    var actions: [DeclarativePluginSettingAction] = []
}

struct PluginManagementIssue: Equatable, Sendable, Identifiable {
    let pluginID: PluginID?
    let message: String

    var id: String { "\(pluginID?.rawValue ?? "host"):\(message)" }
}

struct PluginManagementSnapshot: Equatable, Sendable, Identifiable {
    let manifest: PluginManifest
    let origin: PluginInstallationOrigin
    let installationStatus: PluginInstallationStatus
    let isEnabled: Bool
    let isRequired: Bool
    let isRunning: Bool
    let isQuarantined: Bool
    let isSuppressedBySafeMode: Bool
    let requiresRestart: Bool
    let canRollback: Bool
    let statusMessage: String
    /// Marketplace source and approvals of the active version, if any.
    let marketplace: PluginMarketplaceProvenance?
    /// Options the plugin lets the user change; empty when it declares none.
    var settings: [PluginSettingState] = []
    var disk: PluginDiskProvenance? = nil
    /// Something changed in this session (install, update, uninstall, …) that
    /// only a restart applies. Unlike `requiresRestart`, a bundled plugin the
    /// user removed in an earlier session does not count.
    var hasChangesPendingRestart = false
    /// What the plugin's declaration adds to Lithe, in display order.
    var capabilities: [PluginCapability] = []
    /// Declared permissions, as Rust Core normalized them.
    var permissions: [String] = []
    /// Programs Rust Core's install review lists for the installed package;
    /// `nil` when the package cannot be reviewed (built-in feature groups).
    var programs: [PluginProgram]? = nil
    /// The version a rollback restores, if the store kept one.
    var previousVersion: PluginVersion? = nil
    /// What the plugin adds to settings pages besides its settings.
    var contributions = PluginSettingsContributions()

    var id: PluginID { manifest.id }

    func withDeclaration(
        capabilities: [PluginCapability],
        permissions: [String],
        programs: [PluginProgram]?,
        previousVersion: PluginVersion?
    ) -> PluginManagementSnapshot {
        var snapshot = self
        snapshot.capabilities = capabilities
        snapshot.permissions = permissions
        snapshot.programs = programs
        snapshot.previousVersion = previousVersion
        return snapshot
    }

    /// Attaches the host's finding to each setting it was made for.
    func withSettingDiscoveries(_ discoveries: [String: DebugExecutableLookup]) -> PluginManagementSnapshot {
        guard !discoveries.isEmpty else { return self }
        var snapshot = self
        snapshot.settings = settings.map {
            var setting = $0
            setting.discovery = discoveries[$0.id]
            return setting
        }
        return snapshot
    }

    func withContributions(_ contributions: PluginSettingsContributions) -> PluginManagementSnapshot {
        var snapshot = self
        snapshot.contributions = contributions
        return snapshot
    }
}

/// One thing a plugin's declaration adds to Lithe. Derived from the
/// Core-validated declaration only, so the Features tab never shows a
/// capability the host would not load.
struct PluginCapability: Equatable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Sendable {
        case language
        case languageServer
        case run
        case test
        case debug
        case buildSystem
        case projectGenerator
        case toolWindow
        case command
    }

    enum Detail: Equatable, Sendable {
        case none
        /// File extensions and exact file names the language claims.
        case fileTypes([String])
        case packagedServer
        /// Started by a runtime; `packagedRuntime` when the plugin ships it.
        case runtimeServer(tool: String, packagedRuntime: Bool)
        case systemServer(commands: [String])
        /// Lithe's own implementation serves the capability; the plugin only
        /// turns it on for its language.
        case hostIntegration
        case tasks(Int)
    }

    let kind: Kind
    /// Language, build system, tool window, or command ID.
    let subject: String
    let title: String
    let detail: Detail

    var id: String { "\(kind.rawValue):\(subject)" }

    /// Capabilities in kind order, then by title. `descriptor` is `nil` for
    /// built-in feature groups, which only have a module manifest.
    static func capabilities(
        of manifest: PluginManifest,
        descriptor: DeclarativePluginDescriptor?
    ) -> [PluginCapability] {
        var result: [PluginCapability] = []
        let servers = Dictionary(
            (descriptor?.languageServers ?? []).map { ($0.languageID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for language in manifest.languageSupports ?? [] {
            let fileTypes = language.fileExtensions.map { $0.hasPrefix(".") ? $0 : ".\($0)" } + language.fileNames
            result.append(PluginCapability(
                kind: .language, subject: language.id, title: language.displayName,
                detail: fileTypes.isEmpty ? .none : .fileTypes(fileTypes)
            ))
            if language.languageServerModuleID != nil {
                let detail: Detail = switch servers[language.id]?.launch {
                case .packaged?: .packagedServer
                case .runtime(let tool, _, let packagedRuntime)?: .runtimeServer(tool: tool, packagedRuntime: packagedRuntime != nil)
                case .systemCommand(let commands)?: .systemServer(commands: commands)
                case nil: .none
                }
                result.append(PluginCapability(
                    kind: .languageServer, subject: language.id, title: language.displayName, detail: detail
                ))
            }
            let provided: [(Kind, ModuleID?, LanguageHostCapability)] = [
                (.run, language.executionModuleID, .run),
                (.test, language.testingModuleID, .testing),
                (.debug, language.debugModuleID, .debug),
            ]
            for (kind, moduleID, hostCapability) in provided {
                if moduleID != nil {
                    result.append(PluginCapability(kind: kind, subject: language.id, title: language.displayName, detail: .none))
                } else if language.hostCapabilities.contains(hostCapability) {
                    result.append(PluginCapability(
                        kind: kind, subject: language.id, title: language.displayName, detail: .hostIntegration
                    ))
                }
            }
        }
        for buildSystem in descriptor?.buildSystems ?? [] {
            let tasks = buildSystem.tasks.filter { !$0.fromModel }.count
            result.append(PluginCapability(
                kind: .buildSystem, subject: buildSystem.id, title: buildSystem.displayName,
                detail: tasks > 0 ? .tasks(tasks) : .none
            ))
        }
        for generator in descriptor?.projectGenerators ?? [] {
            result.append(PluginCapability(
                kind: .projectGenerator, subject: generator.id, title: generator.displayName, detail: .none
            ))
        }
        for window in descriptor?.ui?.toolWindows ?? [] {
            result.append(PluginCapability(kind: .toolWindow, subject: window.id, title: window.title, detail: .none))
        }
        for command in descriptor?.ui?.commands ?? [] {
            result.append(PluginCapability(kind: .command, subject: command.id, title: command.title, detail: .none))
        }
        let order = Dictionary(uniqueKeysWithValues: Kind.allCases.enumerated().map { ($1, $0) })
        return result.sorted {
            if $0.kind != $1.kind { return order[$0.kind]! < order[$1.kind]! }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.subject < $1.subject
        }
    }
}

extension PluginManaging {
    func setSetting(
        _ value: ToolingJSONValue?,
        id settingID: String,
        for pluginID: PluginID,
        layer: PluginSettingLayer
    ) throws {
        guard layer == .global else { return }
        try setSetting(value, id: settingID, for: pluginID)
    }

    var settingsProjectRootURL: URL? {
        get { nil }
        set {}
    }

    var settingsActiveFileURL: URL? {
        get { nil }
        set {}
    }

    func workspaceConfiguration(forPlugin _: PluginID, languageID _: String) -> ToolingJSONValue? { nil }
}

@MainActor
protocol PluginManaging: AnyObject {
    var snapshots: [PluginManagementSnapshot] { get }
    var issues: [PluginManagementIssue] { get }

    func setEnabled(_ enabled: Bool, for pluginID: PluginID) async throws
    /// Stores the user's value of one plugin setting; `nil` restores the
    /// plugin's default. The plugin's language servers read it at their next start.
    func setSetting(_ value: ToolingJSONValue?, id settingID: String, for pluginID: PluginID) throws
    /// Stores a value in one layer; `.project` writes the open project's
    /// override of a project-scoped setting.
    func setSetting(
        _ value: ToolingJSONValue?,
        id settingID: String,
        for pluginID: PluginID,
        layer: PluginSettingLayer
    ) throws
    /// The project whose overrides settings show and change; nil without one.
    var settingsProjectRootURL: URL? { get set }
    /// The file open in the editor. Settings that name a program built from
    /// it (`main.c` → `main`) look for that program here; nil without one.
    var settingsActiveFileURL: URL? { get set }
    /// What the plugin's server for `languageID` reads through
    /// `workspace/configuration` with the current values; nil when it
    /// declares none.
    func workspaceConfiguration(forPlugin pluginID: PluginID, languageID: String) -> ToolingJSONValue?
    /// Installs a package that the marketplace already downloaded, verified,
    /// and (for community packages) had the user confirm.
    func installMarketplacePackage(
        at packageURL: URL,
        origin: PluginInstallationOrigin,
        provenance: PluginMarketplaceProvenance
    ) throws
    /// Installs the reviewed local snapshot after explicit user approval.
    func installDiskPackage(at packageURL: URL, provenance: PluginDiskProvenance) throws
    func installPackage(at packageURL: URL) throws
    func rollback(_ pluginID: PluginID) throws
    func uninstall(_ pluginID: PluginID) async throws
    /// Brings back a plugin that ships inside the application after the user
    /// removed it.
    func restore(_ pluginID: PluginID) throws
}
