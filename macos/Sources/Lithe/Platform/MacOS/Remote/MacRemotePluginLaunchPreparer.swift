import CryptoKit
import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule

/// Resolves provider declarations only after the approved target package is
/// present. Every returned launch and cleanup retains the original connection.
@MainActor
final class MacRemotePluginLaunchPreparer {
    struct Build {
        let launch: MacPluginLanguageServerLaunchResolver.BuildProviderLaunch
        let owner: Owner
    }

    struct Vcs {
        let launch: MacPluginLanguageServerLaunchResolver.VcsProviderProcess
        let owner: Owner
    }

    struct Owner {
        let core: any LanguageServerRuntimeCore
        let release: @Sendable () async -> Void
        let isCurrent: @MainActor () -> Bool
    }

    let registry: RemoteWorkspaceRegistry
    let packages: any RemotePluginPackageDeploying
    let host: any RemotePluginFileAccess
    let planner: any DeclarativeLanguageServerLaunchPlanning
    let resolver: MacPluginLanguageServerLaunchResolver
    let core: RustCoreBridge

    init(registry: RemoteWorkspaceRegistry, packages: any RemotePluginPackageDeploying,
         host: any RemotePluginFileAccess, planner: any DeclarativeLanguageServerLaunchPlanning,
         resolver: MacPluginLanguageServerLaunchResolver, core: RustCoreBridge) {
        self.registry = registry
        self.packages = packages
        self.host = host
        self.planner = planner
        self.resolver = resolver
        self.core = core
    }

    func identity(_ root: URL) -> String? { registry.resolve(root)?.binding.sessionID }

    func prepareLanguage(_ descriptor: LanguageServerLaunchDescriptor, workspaceURL: URL,
                         tools: any BuildToolResolving, versionChecker: any LanguageServerRuntimeVersionChecking) async throws -> PreparedLanguageServerProcess {
        guard let binding = registry.resolve(workspaceURL)?.binding, let source = descriptor.launchSource else {
            throw CocoaError(.featureUnsupported)
        }
        let prepared = try await prepare(pluginID: source.pluginID, packageURL: source.packageURL,
            workspaceURL: workspaceURL, binding: binding, scope: "language-servers", provider: source.languageID) { manifest, request in
                try self.planner.languageServerLaunchPlan(manifest: manifest, languageID: source.languageID, request: request)
            }
        do {
            // Native integrations own additional filesystem and protocol data.
            // Do not accidentally start them as a generic stdio server.
            guard prepared.plan.hostIntegration == nil else { throw CocoaError(.featureUnsupported) }
            let process = try process(prepared.plan, root: prepared.packageURL,
                settings: resolver.settingValues(forPlugin: source.pluginID, workspaceRootURL: workspaceURL),
                executesProjectCode: false, mayUseNetwork: true)
            let dependencies = process.runtimeTools.map { BuildInvocation.RuntimeDependency(id: $0, hostManaged: true) }
            let candidates: [ExecutableCandidate]
            var runtimes = dependencies
            var requirement: LanguageServerExecutableVersionRequirement?
            switch process.executable {
            case .file(let url): candidates = [.setting(id: "pluginPackage", path: url.path)]
            case .commands(let commands): candidates = commands.map { .command($0) }
            case .runtime(let tool, let version):
                candidates = [.runtime(tool)]
                requirement = version
                runtimes.insert(.init(id: tool, hostManaged: true, minimumVersion: version?.minimumVersion,
                    versionArguments: version?.probeArguments), at: 0)
            }
            let version = requirement
            let resolved = try await tools.resolve(BuildInvocation(executables: candidates, runtimeDependencies: runtimes),
                displayName: source.languageID, workspaceURL: workspaceURL, checkVersion: { _, output in
                    guard let version else { return .init(satisfied: true, version: nil) }
                    let checked = try versionChecker.checkRuntimeVersion(version, output: output)
                    return .init(satisfied: checked.satisfied, version: checked.version)
                })
            try Task.checkCancellation()
            guard prepared.owner.isCurrent() else { throw CancellationError() }
            var environment = resolved.environment
            environment.merge(descriptor.environment) { _, configured in configured }
            return PreparedLanguageServerProcess(executableURL: resolved.executableURL, environment: environment,
                launch: ResolvedLanguageServerLaunch(arguments: prepared.plan.arguments,
                    initializationOptions: prepared.plan.initializationOptions, workspaceConfiguration: prepared.plan.workspaceConfiguration),
                core: prepared.owner.core, release: prepared.owner.release)
        } catch { await prepared.owner.release(); throw error }
    }

    func prepareBuild(_ target: BuildProviderTarget) async throws -> Build? {
        guard let binding = registry.resolve(target.workspaceURL)?.binding else { return nil }
        let prepared = try await prepare(pluginID: target.pluginID, packageURL: target.packageURL,
            workspaceURL: target.workspaceURL, binding: binding, scope: "build-systems", provider: target.buildSystemID) { manifest, request in
                try self.planner.buildProviderLaunchPlan(manifest: manifest, buildSystemID: target.buildSystemID, request: request)
            }
        do {
            guard let provider = prepared.plan.buildProvider, provider.buildSystemID == target.buildSystemID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let launch: MacPluginLanguageServerLaunchResolver.BuildProviderLaunch
            if let language = provider.languageServer { launch = .languageServer(language) }
            else {
                launch = .process(try process(prepared.plan, root: prepared.packageURL,
                    settings: resolver.settingValues(forPlugin: target.pluginID, workspaceRootURL: target.workspaceURL),
                    executesProjectCode: provider.executesProjectCode, mayUseNetwork: provider.mayUseNetwork))
            }
            return Build(launch: launch, owner: prepared.owner)
        } catch { await prepared.owner.release(); throw error }
    }

    func prepareVcs(_ target: VcsProviderTarget) async throws -> Vcs? {
        guard let binding = registry.resolve(target.workspaceURL)?.binding else { return nil }
        let prepared = try await prepare(pluginID: target.pluginID, packageURL: target.packageURL,
            workspaceURL: target.workspaceURL, binding: binding, scope: "vcs-providers", provider: target.vcs) { manifest, request in
                try self.planner.vcsProviderLaunchPlan(manifest: manifest, vcs: target.vcs, request: request)
            }
        do {
            guard let provider = prepared.plan.vcsProvider, provider.vcs == target.vcs else { throw CocoaError(.fileReadCorruptFile) }
            let process = try process(prepared.plan, root: prepared.packageURL,
                settings: resolver.settingValues(forPlugin: target.pluginID, workspaceRootURL: target.workspaceURL),
                executesProjectCode: false, mayUseNetwork: provider.mayUseNetwork)
            return Vcs(launch: .init(process: process, vcs: provider.vcs, toolCommands: provider.toolCommands,
                toolValidationArguments: provider.toolValidationArguments), owner: prepared.owner)
        } catch { await prepared.owner.release(); throw error }
    }

    private struct Prepared {
        let plan: DeclarativeLanguageServerLaunchPlan
        let packageURL: URL
        let owner: Owner
    }

    private func prepare(pluginID: String, packageURL: URL, workspaceURL: URL, binding: RemoteWorkspaceBinding,
                         scope: String, provider: String,
                         plan: (Data, DeclarativeLanguageServerLaunchRequest) throws -> DeclarativeLanguageServerLaunchPlan) async throws -> Prepared {
        let deployed = try await packages.deploy(pluginID: pluginID, packageURL: packageURL, session: binding.sessionID)
        do {
            try Task.checkCancellation()
            let facts = try await host.pluginHost(session: binding.sessionID)
            guard let home = facts.homeDirectory, home.hasPrefix("/"), !home.contains("\0") else { throw CocoaError(.fileReadCorruptFile) }
            let state = URL(fileURLWithPath: home).appendingPathComponent(".lithe-server/state/plugins")
                .appendingPathComponent(digest(pluginID)).appendingPathComponent(scope).appendingPathComponent(digest(provider))
            let workspaceState = state.appendingPathComponent("workspaces").appendingPathComponent(digest(binding.remoteRoot))
            let request = DeclarativeLanguageServerLaunchRequest(pluginDirectory: deployed.packageURL, stateDirectory: state,
                workspaceStateDirectory: workspaceState, architecture: deployed.architecture,
                settings: resolver.globalSettingValues(forPlugin: pluginID),
                projectSettings: resolver.projectSettingValues(forPlugin: pluginID, workspaceRootURL: workspaceURL))
            let expanded = try plan(deployed.manifest, request)
            for path in expanded.requiredPackagePaths {
                let value = try await host.pluginRequest("fs.stat", params: .object([
                    "path": .string(deployed.packageURL.appendingPathComponent(path).path)]), session: binding.sessionID)
                guard case .object(let metadata) = value,
                      metadata["kind"] == .string("file") || metadata["kind"] == .string("directory") else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            for directory in expanded.requiredDirectories {
                let url = directory == .state ? state : workspaceState
                _ = try await host.pluginRequest("fs.createDir", params: .object([
                    "path": .string(url.path), "recursive": .bool(true), "mode": .integer(0o700)]), session: binding.sessionID)
            }
            try Task.checkCancellation()
            guard identity(workspaceURL) == binding.sessionID else { throw CancellationError() }
            let fixed = RemoteWorkspaceRegistry()
            fixed.register(binding)
            var fixedCore = core
            fixedCore.remoteWorkspaces = fixed
            return Prepared(plan: expanded, packageURL: deployed.packageURL,
                owner: Owner(core: fixedCore, release: deployed.release, isCurrent: {
                    self.identity(workspaceURL) == binding.sessionID
                }))
        } catch { await deployed.release(); throw error }
    }

    private func process(_ plan: DeclarativeLanguageServerLaunchPlan, root: URL,
                         settings: [String: ToolingJSONValue], executesProjectCode: Bool,
                         mayUseNetwork: Bool) throws -> MacPluginLanguageServerLaunchResolver.BuildProviderProcess {
        let executable: MacPluginLanguageServerLaunchResolver.BuildProviderProcess.Executable
        switch plan.executable {
        case .packaged(let path)?: executable = .file(root.appendingPathComponent(path))
        case .systemCommand(let commands)?: executable = .commands(commands)
        case .runtime(let tool)?:
            executable = plan.packagedRuntimePath.map { .file(root.appendingPathComponent($0)) }
                ?? .runtime(tool, versionRequirement: plan.executableVersionRequirement)
        case nil: throw CocoaError(.fileReadCorruptFile)
        }
        return .init(executable: executable, arguments: plan.arguments, initializationOptions: plan.initializationOptions,
            runtimeTools: plan.runtimeRequirements.map(\.tool), executesProjectCode: executesProjectCode,
            mayUseNetwork: mayUseNetwork, settings: settings)
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
