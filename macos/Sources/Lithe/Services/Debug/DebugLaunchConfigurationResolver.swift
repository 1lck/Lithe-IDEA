import Foundation
import LitheModuleAPI
import LitheCoreContracts

enum DebugLaunchConfigurationResolutionError: LocalizedError, Equatable {
    case unsupportedProvider(String)
    case providerDebugUnavailable
    /// No program to debug: the plugin's setting is empty and none of its
    /// candidate locations holds one.
    case executableNotFound(plugin: String, setting: String, searched: [String])
    /// The user chose a program in the plugin's setting that cannot run.
    case configuredExecutableUnusable(plugin: String, setting: String, path: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return L10n.string("The \(provider) Debug Adapter is not installed yet.")
        case .providerDebugUnavailable:
            return L10n.string("The build provider's debug program or adapter is unavailable. Build it again and check that the plugin is enabled.")
        case .executableNotFound(let plugin, let setting, let searched):
            if searched.isEmpty {
                return L10n.string("No program to debug was found. Build it first, or choose one in the “\(setting)” setting of \(plugin).")
            }
            let places = searched.joined(separator: ", ")
            return L10n.string("No program to debug was found. Build it first, or choose one in the “\(setting)” setting of \(plugin). Looked in: \(places)")
        case .configuredExecutableUnusable(let plugin, let setting, let path):
            return L10n.string("The program chosen in the “\(setting)” setting of \(plugin) is missing or not executable: \(path)")
        }
    }
}

/// The adapter registry owns the binding throughout process preparation and attach.
@MainActor
struct PreparedProviderConnectionDebug {
    let options: BuildLaunchOptions.Debug
    let configuration: DebugLaunchConfiguration
    let isCurrent: @MainActor @Sendable () -> Bool
}

/// Maps an editor target into adapter launch arguments. It contains no process
/// or UI code, so platform composition supplies only the plugin launch
/// capabilities.
struct DebugLaunchConfigurationResolver {
    /// The launch of a language a plugin's debug adapter serves. Returns nil
    /// when no adapter serves the language.
    private let pluginLaunch: (@MainActor (_ languageID: String, _ documentURL: URL, _ workspaceURL: URL) throws -> DebugLaunchConfiguration?)?

    private let providerConnection: (@MainActor (String, String?, UInt16) throws -> PreparedProviderConnectionDebug)?
    private let providerLaunch: (@MainActor (BuildSystemPluginSource, BuildDebugPreparation, URL, String) throws -> DebugLaunchConfiguration)?

    @MainActor
    func resolveProvider(source: BuildSystemPluginSource, preparation: BuildDebugPreparation,
                         workspaceURL: URL, title: String) throws -> DebugLaunchConfiguration {
        guard let providerLaunch else { throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable }
        return try providerLaunch(source, preparation, workspaceURL, title)
    }

    @MainActor
    func resolveProviderConnection(configurationType: String, adapterID: String?, port: UInt16) throws -> PreparedProviderConnectionDebug {
        guard let providerConnection else { throw DebugLaunchConfigurationResolutionError.providerDebugUnavailable }
        return try providerConnection(configurationType, adapterID, port)
    }

    init(
        providerConnection: (@MainActor (String, String?, UInt16) throws -> PreparedProviderConnectionDebug)? = nil,
        providerLaunch: (@MainActor (BuildSystemPluginSource, BuildDebugPreparation, URL, String) throws -> DebugLaunchConfiguration)? = nil,
        pluginLaunch: (@MainActor (String, URL, URL) throws -> DebugLaunchConfiguration?)? = nil
    ) {
        self.providerConnection = providerConnection
        self.providerLaunch = providerLaunch
        self.pluginLaunch = pluginLaunch
    }

    @MainActor
    func resolve(
        provider: LanguageProviderDescriptor,
        documentURL: URL,
        workspaceURL: URL
    ) throws -> DebugLaunchConfiguration {
        if let configuration = try pluginLaunch?(provider.id, documentURL, workspaceURL) {
            return configuration
        }
        throw DebugLaunchConfigurationResolutionError.unsupportedProvider(provider.displayName)
    }
}
