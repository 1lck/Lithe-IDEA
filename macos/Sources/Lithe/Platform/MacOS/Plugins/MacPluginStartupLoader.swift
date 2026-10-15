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
    /// Accepted packages whose host-owned modules are registered for this
    /// process. Enablement only decides whether those modules may activate,
    /// so a package is registered even while it is disabled.
    let registeredPlugins: [InstalledPluginPackage]
    let issues: [PluginStartupIssue]
    var iconResources: [String: PluginUIIconResources] = [:]
    /// `false` when the installed packages could not be scanned at all, so an
    /// empty `installedPlugins` means "unknown" rather than "none installed".
    var scanSucceeded = true

    var installedManifests: [PluginManifest] {
        installedPlugins.map(\.manifest).sorted { $0.id < $1.id }
    }

    var registeredManifests: [PluginManifest] {
        registeredPlugins.map(\.manifest).sorted { $0.id < $1.id }
    }

    var installedLanguageSupports: [LanguageSupportDeclaration] {
        installedManifests
            .flatMap { $0.languageSupports ?? [] }
            .sorted { $0.id < $1.id }
    }
}

// Note: 声明式插件不加载任何插件代码，启动流程见 .agents/notes/implemented/architecture/2026-10-12-declarative-language-plugins.md
/// Scans installed declarative plugins and checks their static module graph
/// against the built-in catalog. No plugin code is loaded: accepted packages
/// only contribute host-owned module factories. Failures stay local to plugin
/// startup and never replace the required built-in catalog.
@MainActor
final class MacPluginStartupLoader {
    /// Rejects a candidate catalog whose UI contributions cannot bind to host
    /// actions and renderers. Those bindings live in the Views layer, so the
    /// composition root supplies the check instead of this adapter importing it.
    typealias UIValidator = @MainActor (ValidatedPluginCatalog) throws -> Void

    private let packageStore: MacPluginPackageStore
    private let hostVersion: PluginVersion
    private let validateUI: UIValidator

    init(
        packageStore: MacPluginPackageStore,
        hostVersion: PluginVersion = BuiltInPluginCatalog.hostVersion,
        validateUI: @escaping UIValidator
    ) {
        self.packageStore = packageStore
        self.hostVersion = hostVersion
        self.validateUI = validateUI
    }

    func load(recoveryStore: (any ModuleRecoveryStore)?) -> MacPluginStartupResult {
        clearRetiredNativeLoadMarker(using: recoveryStore)
        let scan: PluginPackageScanResult
        do {
            try packageStore.prepareForLaunch()
            scan = try packageStore.scanInstalledPlugins()
        } catch {
            return MacPluginStartupResult(
                installedPlugins: [],
                registeredPlugins: [],
                issues: [PluginStartupIssue(pluginID: nil, message: error.localizedDescription)],
                scanSucceeded: false
            )
        }

        var accepted: [InstalledPluginPackage] = []
        var iconResources: [String: PluginUIIconResources] = [:]
        var issues = scan.issues.map {
            PluginStartupIssue(pluginID: $0.pluginID, message: $0.message)
        }
        for installed in scan.packages.sorted(by: { $0.manifest.id < $1.manifest.id }) {
            // A removed bundled plugin stays listed so it can be restored and
            // keeps owning its language, but none of its modules are registered.
            guard installed.installation.status != .removed else { continue }
            do {
                // Include every accepted candidate so plugin, module, and
                // language ownership collisions are rejected per package.
                let catalog = try ValidatedPluginCatalog(
                    manifests: BuiltInPluginCatalog.manifests
                        + BundledLanguagePluginCatalog.manifests
                        + accepted.map(\.manifest)
                        + [installed.manifest],
                    hostVersion: hostVersion
                )
                // Validate renderer/action bindings before any workspace can
                // construct its UI; a rejected package remains inspectable.
                try validateUI(catalog)
                let icons = try MacPluginUIIconLoader.load(installed.descriptor, at: installed.packageURL)
                iconResources.merge(icons) { _, new in new }
                accepted.append(installed)
            } catch {
                issues.append(PluginStartupIssue(
                    pluginID: installed.manifest.id,
                    message: error.localizedDescription
                ))
            }
        }

        do {
            try validateStaticGraph(
                manifests: BuiltInPluginCatalog.manifests
                    + BundledLanguagePluginCatalog.manifests
                    + accepted.map(\.manifest)
            )
        } catch {
            issues.append(PluginStartupIssue(pluginID: nil, message: error.localizedDescription))
            accepted.removeAll()
            iconResources.removeAll()
        }

        Self.log(issues)
        return MacPluginStartupResult(
            installedPlugins: scan.packages,
            registeredPlugins: accepted,
            issues: issues, iconResources: iconResources
        )
    }

    /// Rejected or failed plugins are otherwise only visible in Plugin
    /// Management, so record them in the unified log for diagnosis.
    private static func log(_ issues: [PluginStartupIssue]) {
        for issue in issues {
            NSLog(
                "Lithe plugin startup issue [%@]: %@",
                issue.pluginID?.rawValue ?? "-",
                issue.message
            )
        }
    }

    /// Earlier releases kept a process-lifetime marker while native plugin
    /// code was mapped and quarantined those modules after an abnormal exit.
    /// Declarative plugins run no code in this process, so a leftover marker
    /// is cleared instead of quarantining the declarative replacements.
    private func clearRetiredNativeLoadMarker(using recoveryStore: (any ModuleRecoveryStore)?) {
        guard let recoveryStore, !recoveryStore.pendingPluginLoadModules().isEmpty else { return }
        recoveryStore.setPendingPluginLoadModules([])
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
