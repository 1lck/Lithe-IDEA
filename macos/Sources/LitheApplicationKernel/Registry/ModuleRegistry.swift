import Foundation
import LitheModuleAPI

/// Declarative registration surface for the application composition root.
/// A feature module contributes one factory; lifecycle and graph validation
/// remain centralized in ModuleRuntime.
@MainActor
public final class ModuleRegistry {
    private let runtime: ModuleRuntime
    private let pluginManifests: [PluginManifest]
    private let hostVersion: PluginVersion
    private var factories: [ModuleID: ModuleFactory] = [:]

    public init(
        runtime: ModuleRuntime,
        pluginManifests: [PluginManifest] = BuiltInPluginCatalog.manifests,
        hostVersion: PluginVersion = BuiltInPluginCatalog.hostVersion
    ) {
        self.runtime = runtime
        self.pluginManifests = pluginManifests
        self.hostVersion = hostVersion
    }

    public func register(_ factory: ModuleFactory) throws {
        guard factories[factory.manifest.id] == nil else {
            throw ModuleRuntimeError.duplicateModule(factory.manifest.id)
        }
        factories[factory.manifest.id] = factory
        try runtime.register(factory)
    }

    public func validate() throws {
        let catalog = try ValidatedPluginCatalog(
            manifests: pluginManifests,
            hostVersion: hostVersion
        )
        for required in BuiltInModuleCatalog.manifests.filter(\.isRequired) {
            guard catalog.modules[required.id] != nil, factories[required.id] != nil else {
                throw PluginCatalogError.missingRequiredModule(required.id)
            }
        }
        for (moduleID, factory) in factories {
            guard let ownership = catalog.modules[moduleID] else {
                throw PluginCatalogError.factoryWithoutInstalledPlugin(moduleID)
            }
            guard ownership.declaration.manifest == factory.manifest,
                  ownership.declaration.contributions == factory.contributions else {
                throw PluginCatalogError.moduleFactoryMismatch(
                    plugin: ownership.pluginID,
                    module: moduleID
                )
            }
        }
        for (moduleID, ownership) in catalog.modules where factories[moduleID] == nil {
            throw PluginCatalogError.missingModuleFactory(
                plugin: ownership.pluginID,
                module: moduleID
            )
        }
        try runtime.validateGraph()
    }

    public func startEagerModules() async throws {
        try await runtime.startEagerModules()
    }

    public var registeredModuleIDs: [ModuleID] {
        factories.keys.sorted()
    }
}
