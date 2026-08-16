import Foundation
import LitheModuleAPI

protocol PluginPrincipalClassLoading {
    func principalClass(at bundleURL: URL) throws -> AnyClass
}

enum NativePluginLoaderError: Error, Equatable, LocalizedError {
    case invalidBundlePath(PluginID)
    case bundleCouldNotLoad(PluginID)
    case invalidPrincipalClass(PluginID)
    case factoryCatalogMismatch(PluginID)

    var errorDescription: String? {
        switch self {
        case .invalidBundlePath(let id): "Plugin \(id) has an invalid bundle path."
        case .bundleCouldNotLoad(let id): "Plugin \(id) bundle could not be loaded."
        case .invalidPrincipalClass(let id): "Plugin \(id) does not expose a valid Lithe entrypoint."
        case .factoryCatalogMismatch(let id): "Plugin \(id) factories differ from its static manifest."
        }
    }
}

struct MacPluginLoadPolicy {
    let configurationStore: (any ModuleConfigurationStore)?
    let recoveryStore: (any ModuleRecoveryStore)?
    let launchMode: ModuleLaunchMode

    func shouldLoad(_ plugin: PluginManifest) -> Bool {
        if plugin.modules.contains(where: { $0.manifest.isRequired }) {
            return true
        }
        guard launchMode == .normal else { return false }
        return plugin.modules.contains { declaration in
            let manifest = declaration.manifest
            let enabled = configurationStore?.enabledState(for: manifest.id)
                ?? (manifest.defaultState == .enabled)
            return enabled && !(recoveryStore?.isQuarantined(manifest.id) ?? false)
        }
    }
}

@MainActor
final class MacNativePluginLoader {
    private let codeLoader: any PluginPrincipalClassLoading
    private let hostContext: PluginHostContext

    init(codeLoader: any PluginPrincipalClassLoading = MacBundlePrincipalClassLoader()) {
        self.codeLoader = codeLoader
        hostContext = .empty
    }

    init(
        codeLoader: any PluginPrincipalClassLoading = MacBundlePrincipalClassLoader(),
        hostContext: PluginHostContext
    ) {
        self.codeLoader = codeLoader
        self.hostContext = hostContext
    }

    func loadFactories(
        from installedPlugins: [InstalledPluginPackage],
        policy: MacPluginLoadPolicy
    ) throws -> [PluginID: [ModuleFactory]] {
        var result: [PluginID: [ModuleFactory]] = [:]
        for installed in installedPlugins.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            let manifest = installed.manifest
            guard policy.shouldLoad(manifest) else { continue }
            guard manifest.entrypoint.kind == .nativeBundle,
                  let bundlePath = manifest.entrypoint.bundlePath,
                  Self.isSafeRelativePath(bundlePath) else {
                throw NativePluginLoaderError.invalidBundlePath(manifest.id)
            }
            let bundleURL = installed.packageURL
                .appendingPathComponent(bundlePath)
                .standardizedFileURL
            guard bundleURL.path.hasPrefix(installed.packageURL.standardizedFileURL.path + "/") else {
                throw NativePluginLoaderError.invalidBundlePath(manifest.id)
            }
            let principalClass: AnyClass = try codeLoader.principalClass(at: bundleURL)
            guard let entrypointType = principalClass as? LithePluginEntrypoint.Type else {
                throw NativePluginLoaderError.invalidPrincipalClass(manifest.id)
            }
            let factories = try entrypointType.init().moduleFactories(context: hostContext).sorted {
                $0.manifest.id < $1.manifest.id
            }
            let declarations = manifest.modules.sorted { $0.manifest.id < $1.manifest.id }
            guard factories.count == declarations.count,
                  zip(factories, declarations).allSatisfy({ factory, declaration in
                      factory.manifest == declaration.manifest
                          && factory.contributions == declaration.contributions
                  }) else {
                throw NativePluginLoaderError.factoryCatalogMismatch(manifest.id)
            }
            result[manifest.id] = factories
        }
        return result
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

struct MacBundlePrincipalClassLoader: PluginPrincipalClassLoading {
    func principalClass(at bundleURL: URL) throws -> AnyClass {
        guard let bundle = Bundle(url: bundleURL) else {
            throw NativePluginLoaderError.bundleCouldNotLoad(PluginID(bundleURL.lastPathComponent))
        }
        try bundle.loadAndReturnError()
        guard let principalClass = bundle.principalClass else {
            throw NativePluginLoaderError.bundleCouldNotLoad(
                PluginID(bundle.bundleIdentifier ?? bundleURL.lastPathComponent)
            )
        }
        return principalClass
    }
}
