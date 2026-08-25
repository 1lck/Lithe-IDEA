import Foundation
import LitheModuleAPI

public enum PluginCatalogError: Error, Equatable, LocalizedError, Sendable {
    case duplicatePlugin(PluginID)
    case duplicateModule(module: ModuleID, plugins: [PluginID])
    case duplicateLanguageSupport(languageID: String, plugins: [PluginID])
    case unsupportedSchema(plugin: PluginID, version: Int)
    case unsupportedAPI(plugin: PluginID, version: Int)
    case incompatibleHost(plugin: PluginID, hostVersion: PluginVersion)
    case emptyPlugin(PluginID)
    case invalidEntrypoint(PluginID)
    case invalidLanguageSupport(plugin: PluginID, languageID: String)
    case missingRequiredModule(ModuleID)
    case missingModuleFactory(plugin: PluginID, module: ModuleID)
    case factoryWithoutInstalledPlugin(ModuleID)
    case moduleFactoryMismatch(plugin: PluginID, module: ModuleID)

    public var errorDescription: String? {
        switch self {
        case .duplicatePlugin(let id): "Plugin \(id) is declared more than once."
        case .duplicateModule(let module, let plugins):
            "Module \(module) is declared by multiple plugins: \(plugins.map(\.rawValue).joined(separator: ", "))."
        case .duplicateLanguageSupport(let languageID, let plugins):
            "Language support \(languageID) is declared by multiple plugins: \(plugins.map(\.rawValue).joined(separator: ", "))."
        case .unsupportedSchema(let plugin, let version):
            "Plugin \(plugin) uses unsupported manifest schema \(version)."
        case .unsupportedAPI(let plugin, let version):
            "Plugin \(plugin) requires unsupported Plugin API \(version)."
        case .incompatibleHost(let plugin, let hostVersion):
            "Plugin \(plugin) is not compatible with Lithe \(hostVersion)."
        case .emptyPlugin(let plugin): "Plugin \(plugin) declares no modules."
        case .invalidEntrypoint(let plugin): "Plugin \(plugin) has invalid entrypoint metadata."
        case .invalidLanguageSupport(let plugin, let languageID):
            "Plugin \(plugin) has an invalid language support declaration for \(languageID)."
        case .missingRequiredModule(let module): "Required module \(module) is not installed."
        case .missingModuleFactory(let plugin, let module):
            "Installed plugin \(plugin) did not register module \(module)."
        case .factoryWithoutInstalledPlugin(let module):
            "Module \(module) registered code without an installed static plugin manifest."
        case .moduleFactoryMismatch(let plugin, let module):
            "Module \(module) factory differs from plugin \(plugin)'s static manifest."
        }
    }
}

public struct PluginModuleOwnership: Equatable, Sendable {
    public let pluginID: PluginID
    public let declaration: PluginModuleDeclaration
}

public struct PluginLanguageSupportOwnership: Equatable, Sendable {
    public let pluginID: PluginID
    public let declaration: LanguageSupportDeclaration
}

public struct ValidatedPluginCatalog: Sendable {
    public let manifests: [PluginManifest]
    public let modules: [ModuleID: PluginModuleOwnership]
    public let languageSupports: [String: PluginLanguageSupportOwnership]

    public init(
        manifests: [PluginManifest],
        hostVersion: PluginVersion,
        supportedAPIVersion: Int = PluginManifest.currentAPIVersion
    ) throws {
        var pluginIDs: Set<PluginID> = []
        var modules: [ModuleID: PluginModuleOwnership] = [:]
        var languageSupports: [String: PluginLanguageSupportOwnership] = [:]
        for plugin in manifests.sorted(by: { $0.id < $1.id }) {
            guard pluginIDs.insert(plugin.id).inserted else {
                throw PluginCatalogError.duplicatePlugin(plugin.id)
            }
            guard plugin.schemaVersion == PluginManifest.currentSchemaVersion else {
                throw PluginCatalogError.unsupportedSchema(
                    plugin: plugin.id,
                    version: plugin.schemaVersion
                )
            }
            guard plugin.apiVersion == supportedAPIVersion else {
                throw PluginCatalogError.unsupportedAPI(plugin: plugin.id, version: plugin.apiVersion)
            }
            guard plugin.hostCompatibility.contains(hostVersion) else {
                throw PluginCatalogError.incompatibleHost(
                    plugin: plugin.id,
                    hostVersion: hostVersion
                )
            }
            guard !plugin.modules.isEmpty else {
                throw PluginCatalogError.emptyPlugin(plugin.id)
            }
            switch plugin.entrypoint.kind {
            case .builtIn:
                guard plugin.entrypoint.targetName?.isEmpty == false,
                      plugin.entrypoint.bundleIdentifier == nil,
                      plugin.entrypoint.principalClass == nil,
                      plugin.entrypoint.bundlePath == nil else {
                    throw PluginCatalogError.invalidEntrypoint(plugin.id)
                }
            case .nativeBundle:
                guard plugin.entrypoint.targetName == nil,
                      plugin.entrypoint.bundleIdentifier?.isEmpty == false,
                      plugin.entrypoint.principalClass?.isEmpty == false,
                      Self.isSafeRelativePath(plugin.entrypoint.bundlePath) else {
                    throw PluginCatalogError.invalidEntrypoint(plugin.id)
                }
            }
            for declaration in plugin.modules {
                let moduleID = declaration.manifest.id
                if let existing = modules[moduleID] {
                    throw PluginCatalogError.duplicateModule(
                        module: moduleID,
                        plugins: [existing.pluginID, plugin.id].sorted()
                    )
                }
                modules[moduleID] = PluginModuleOwnership(
                    pluginID: plugin.id,
                    declaration: declaration
                )
            }
            try Self.validateLanguageSupports(in: plugin)
            for support in plugin.languageSupports ?? [] {
                if let existing = languageSupports[support.id] {
                    throw PluginCatalogError.duplicateLanguageSupport(
                        languageID: support.id,
                        plugins: [existing.pluginID, plugin.id].sorted()
                    )
                }
                languageSupports[support.id] = PluginLanguageSupportOwnership(
                    pluginID: plugin.id,
                    declaration: support
                )
            }
        }
        self.manifests = manifests.sorted { $0.id < $1.id }
        self.modules = modules
        self.languageSupports = languageSupports
    }

    public func languageSupport(for fileURL: URL) -> PluginLanguageSupportOwnership? {
        languageSupports.values
            .filter { $0.declaration.handles(fileURL: fileURL) }
            .sorted { $0.declaration.id < $1.declaration.id }
            .first
    }

    public func languageSupports(
        recognizingProjectFileNames fileNames: some Sequence<String>
    ) -> [PluginLanguageSupportOwnership] {
        languageSupports.values
            .filter { $0.declaration.recognizesProject(fileNames: fileNames) }
            .sorted { $0.declaration.id < $1.declaration.id }
    }

    private static func isSafeRelativePath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func validateLanguageSupports(in plugin: PluginManifest) throws {
        let declaredModuleIDs = Set(plugin.modules.map(\.manifest.id))
        var languageIDs: Set<String> = []
        for support in plugin.languageSupports ?? [] {
            let moduleIDs = support.moduleIDs
            let hasRecognitionMetadata = !support.fileExtensions.isEmpty
                || !support.fileNames.isEmpty
                || !support.projectFileNames.isEmpty
            let normalizedID = support.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hasInvalidName = support.id != normalizedID
                || normalizedID.isEmpty
                || support.displayName.isEmpty
                || support.fileExtensions.contains(where: { $0.contains("/") || $0.hasPrefix(".") })
                || support.fileNames.contains(where: { $0.contains("/") })
                || support.projectFileNames.contains(where: { $0.contains("/") })
            guard languageIDs.insert(support.id).inserted,
                  hasRecognitionMetadata,
                  !hasInvalidName,
                  !moduleIDs.isEmpty,
                  moduleIDs.allSatisfy(declaredModuleIDs.contains) else {
                throw PluginCatalogError.invalidLanguageSupport(
                    plugin: plugin.id,
                    languageID: support.id
                )
            }
        }
    }
}
