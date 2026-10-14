import Foundation
import LitheCoreContracts

// Note: Java 语言服务器插件化与 jdt 宿主集成见 .agents/notes/implemented/architecture/2026-10-13-java-language-server-as-declarative-plugin.md

/// The `jdt` host integration: Eclipse JDT LS started through the shared JDT
/// launch in Rust Core. The declaring plugin ships JDT LS and its JDK; this
/// type locates them through the plugin's declaration, runs the server on the
/// plugin's runtime, and owns the per-workspace index in the host cache.
@MainActor
final class MacJdtHostIntegration: MacLanguageServerHostIntegration {
    nonisolated static let integrationID = "jdt"

    let id = MacJdtHostIntegration.integrationID

    private let launchResolver: MacPluginLanguageServerLaunchResolver
    private let runtimeService: ProjectRuntimeService
    private let workspaceState: MacJdtWorkspaceState
    private let launchResources = MacJdtLaunchResources()

    init(
        launchResolver: MacPluginLanguageServerLaunchResolver,
        runtimeService: ProjectRuntimeService,
        workspaceState: MacJdtWorkspaceState
    ) {
        self.launchResolver = launchResolver
        self.runtimeService = runtimeService
        self.workspaceState = workspaceState
    }

    /// JDT LS runs on the JDK its plugin ships. The host only learns where
    /// that JDK is from the plugin's declaration; without a declaring plugin
    /// the Java language service is unavailable.
    func pluginsDidLoad(_ plugins: [InstalledPluginPackage]) {
        runtimeService.setJavaLanguageServerRuntimeHome(runtimeHome(in: plugins))
    }

    func launch(
        for source: DeclarativeLanguageServerLaunchSource
    ) -> LanguageServerHostIntegrationResolution {
        guard let runtimeExecutableURL = runtimeService.javaLanguageServerExecutableURL() else {
            return .unavailable(
                runtimeService.javaLanguageServerRuntimeFailureMessage()
                    ?? "The Java Support plugin's runtime is not prepared."
            )
        }
        do {
            guard let declared = try launchResolver.hostIntegration(for: source) else {
                return .unavailable("The Java Support plugin does not declare its JDT LS files. Reinstall the plugin.")
            }
            // JDT LS binds each project to the installed JDK that matches its
            // release; the JDK it runs on cannot build a project for a newer
            // Java release.
            let discovered = runtimeService.javaRuntimes.isEmpty
                ? MacRuntimeDiscovery.discover(environment: ProcessInfo.processInfo.environment).javaRuntimes
                : runtimeService.javaRuntimes
            let resources = try launchResources.resources(
                from: declared,
                javaRuntimes: discovered.map {
                    JavaLanguageServiceRuntime(homePath: $0.homePath, version: $0.version)
                }
            )
            return .available(LanguageServerHostIntegrationLaunch(
                runtimeExecutableURL: runtimeExecutableURL,
                coreLaunch: .jdt(resources)
            ))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    func workspaceFingerprint(
        for source: DeclarativeLanguageServerLaunchSource,
        workspaceRootURL: URL
    ) throws -> String? {
        guard let declared = try launchResolver.hostIntegration(for: source) else { return nil }
        // The launcher identifies the JDT LS installation whose version and
        // location the index depends on.
        return try workspaceState.fingerprint(
            at: workspaceRootURL,
            languageServerExecutableURL: declared.entryURL
        )
    }

    func resetWorkspaceState(at workspaceRootURL: URL, fingerprint: String?) throws {
        try workspaceState.clearIndex(at: workspaceRootURL, workspaceFingerprint: fingerprint)
    }

    func pruneWorkspaceState(at workspaceRootURL: URL, fingerprint: String?) throws -> Int {
        try workspaceState.pruneExpiredCaches(
            at: workspaceRootURL,
            workspaceFingerprint: fingerprint
        ).removedWorkspaceKeys.count
    }

    /// JDK home of the runtime shipped by the plugin that declares this
    /// integration, or `nil` when no installed plugin does.
    func runtimeHome(in plugins: [InstalledPluginPackage]) -> URL? {
        for installed in plugins {
            for server in installed.descriptor.languageServers where server.hostIntegrationID == id {
                let source = DeclarativeLanguageServerLaunchSource(
                    pluginID: installed.descriptor.id.rawValue,
                    languageID: server.languageID,
                    manifest: installed.descriptor.normalizedManifest,
                    packageURL: installed.packageURL
                )
                // `<home>/bin/java`
                if let java = try? launchResolver.executableProbe(for: source).packagedRuntimeURL {
                    return java.deletingLastPathComponent().deletingLastPathComponent()
                }
            }
        }
        return nil
    }
}
