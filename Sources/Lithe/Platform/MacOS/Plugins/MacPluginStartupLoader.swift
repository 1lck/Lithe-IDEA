import Foundation
import LitheApplicationKernel
import LitheModuleAPI

struct PluginStartupIssue: Equatable {
    let pluginID: PluginID?
    let message: String
}

@MainActor
struct MacPluginStartupResult {
    let installedPlugins: [InstalledPluginPackage]
    let activeNativeManifests: [PluginManifest]
    let factoriesByPlugin: [PluginID: [ModuleFactory]]
    let issues: [PluginStartupIssue]

    var installedManifests: [PluginManifest] {
        installedPlugins.map(\.manifest).sorted { $0.id < $1.id }
    }

    var installedLanguageSupports: [LanguageSupportDeclaration] {
        installedManifests
            .flatMap { $0.languageSupports ?? [] }
            .sorted { $0.id < $1.id }
    }
}

/// Establishes the native-code loading boundary for optional plugins. Static
/// metadata and signatures are checked before a bundle or principal class is
/// touched. Failures remain local to plugin startup and never replace the
/// required built-in catalog.
@MainActor
final class MacPluginStartupLoader {
    private let packageStore: MacPluginPackageStore
    private let nativeLoader: MacNativePluginLoader
    private let hostVersion: PluginVersion
    private let runtimeRecovery: MacPluginRuntimeRecoveryCoordinator?

    init(
        packageStore: MacPluginPackageStore,
        nativeLoader: MacNativePluginLoader? = nil,
        hostVersion: PluginVersion = BuiltInPluginCatalog.hostVersion,
        runtimeRecovery: MacPluginRuntimeRecoveryCoordinator? = nil
    ) {
        self.packageStore = packageStore
        self.nativeLoader = nativeLoader ?? MacNativePluginLoader()
        self.hostVersion = hostVersion
        self.runtimeRecovery = runtimeRecovery
    }

    func load(policy: MacPluginLoadPolicy) -> MacPluginStartupResult {
        if let recoveryStore = policy.recoveryStore, let runtimeRecovery {
            runtimeRecovery.recoverPreviousSession(using: recoveryStore)
        } else {
            recoverInterruptedPluginLoad(using: policy.recoveryStore)
        }
        let scan: PluginPackageScanResult
        do {
            try packageStore.prepareForLaunch()
            scan = try packageStore.scanInstalledPlugins()
        } catch {
            return MacPluginStartupResult(
                installedPlugins: [],
                activeNativeManifests: [],
                factoriesByPlugin: [:],
                issues: [PluginStartupIssue(pluginID: nil, message: error.localizedDescription)]
            )
        }

        var candidatePackages: [InstalledPluginPackage] = []
        var candidateManifests: [PluginManifest] = []
        var factoriesByPlugin: [PluginID: [ModuleFactory]] = [:]
        var issues = scan.issues.map {
            PluginStartupIssue(pluginID: $0.pluginID, message: $0.message)
        }

        for installed in scan.packages.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            let manifest = installed.manifest
            guard policy.shouldLoad(manifest) else { continue }

            do {
                // Include all accepted candidates in the static catalog check so
                // plugin and module ownership collisions fail before code load.
                _ = try ValidatedPluginCatalog(
                    manifests: BuiltInPluginCatalog.manifests + candidateManifests + [manifest],
                    hostVersion: hostVersion
                )
                candidatePackages.append(installed)
                candidateManifests.append(manifest)
            } catch {
                issues.append(PluginStartupIssue(
                    pluginID: manifest.id,
                    message: error.localizedDescription
                ))
            }
        }

        do {
            try validateStaticGraph(
                manifests: BuiltInPluginCatalog.manifests + candidateManifests
            )
        } catch {
            issues.append(PluginStartupIssue(pluginID: nil, message: error.localizedDescription))
            candidatePackages.removeAll()
            candidateManifests.removeAll()
        }

        var activeNativeManifests: [PluginManifest] = []
        for installed in candidatePackages {
            let moduleIDs = installed.manifest.modules.map(\.manifest.id).sorted()
            if let recoveryStore = policy.recoveryStore, let runtimeRecovery {
                runtimeRecovery.prepareToLoad(moduleIDs, using: recoveryStore)
            } else {
                policy.recoveryStore?.setPendingPluginLoadModules(moduleIDs)
            }
            do {
                let loaded = try nativeLoader.loadFactories(from: [installed], policy: policy)
                guard let factories = loaded[installed.manifest.id] else {
                    clearPendingLoad(using: policy.recoveryStore)
                    continue
                }
                activeNativeManifests.append(installed.manifest)
                factoriesByPlugin[installed.manifest.id] = factories
                if let recoveryStore = policy.recoveryStore, let runtimeRecovery {
                    runtimeRecovery.recordSuccessfulLoad(moduleIDs, using: recoveryStore)
                } else {
                    policy.recoveryStore?.setPendingPluginLoadModules([])
                }
            } catch {
                for moduleID in moduleIDs {
                    policy.recoveryStore?.setQuarantined(true, for: moduleID)
                }
                clearPendingLoad(using: policy.recoveryStore)
                issues.append(PluginStartupIssue(
                    pluginID: installed.manifest.id,
                    message: error.localizedDescription
                ))
            }
        }

        do {
            try validateStaticGraph(
                manifests: BuiltInPluginCatalog.manifests + activeNativeManifests
            )
        } catch {
            issues.append(PluginStartupIssue(pluginID: nil, message: error.localizedDescription))
            activeNativeManifests.removeAll()
            factoriesByPlugin.removeAll()
        }

        return MacPluginStartupResult(
            installedPlugins: scan.packages,
            activeNativeManifests: activeNativeManifests.sorted { $0.id < $1.id },
            factoriesByPlugin: factoriesByPlugin,
            issues: issues
        )
    }

    private func clearPendingLoad(using recoveryStore: (any ModuleRecoveryStore)?) {
        guard let recoveryStore else { return }
        if let runtimeRecovery {
            runtimeRecovery.recordFailedLoad(using: recoveryStore)
        } else {
            recoveryStore.setPendingPluginLoadModules([])
        }
    }

    private func recoverInterruptedPluginLoad(using recoveryStore: (any ModuleRecoveryStore)?) {
        guard let recoveryStore else { return }
        let pending = recoveryStore.pendingPluginLoadModules()
        for moduleID in pending {
            recoveryStore.setQuarantined(true, for: moduleID)
        }
        if !pending.isEmpty {
            recoveryStore.setPendingPluginLoadModules([])
        }
    }

    private func validateStaticGraph(manifests: [PluginManifest]) throws {
        let runtime = ModuleRuntime()
        let registry = ModuleRegistry(
            runtime: runtime,
            pluginManifests: manifests,
            hostVersion: hostVersion
        )
        for declaration in manifests.flatMap(\.modules) {
            try registry.register(ModuleFactory(
                manifest: declaration.manifest,
                contributions: declaration.contributions
            ) {
                throw StaticPluginGraphValidationError.factoryMustNotBeInvoked
            })
        }
        try registry.validate()
    }
}

private enum StaticPluginGraphValidationError: Error {
    case factoryMustNotBeInvoked
}
