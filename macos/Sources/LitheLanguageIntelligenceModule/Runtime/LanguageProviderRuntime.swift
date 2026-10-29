import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// A declarative server's launch after Rust Core expanded its templates and
/// the host prepared the directories and checked the package paths.
package struct ResolvedLanguageServerLaunch: Equatable, Sendable {
    package let arguments: [String]
    package let initializationOptions: ToolingJSONValue?
    /// What the server reads through `workspace/configuration`; plugin
    /// settings with `effect: immediate` change it without a restart.
    package let workspaceConfiguration: ToolingJSONValue?

    package init(
        arguments: [String],
        initializationOptions: ToolingJSONValue?,
        workspaceConfiguration: ToolingJSONValue? = nil
    ) {
        self.arguments = arguments
        self.initializationOptions = initializationOptions
        self.workspaceConfiguration = workspaceConfiguration
    }
}

/// An asynchronous host adapter supplies a complete process and its lifetime
/// before startup. Network work must finish before Core starts the process.
package struct PreparedLanguageServerProcess: Sendable {
    package let executableURL: URL
    package let environment: [String: String]
    package let launch: ResolvedLanguageServerLaunch
    package let core: any LanguageServerRuntimeCore
    package let release: @Sendable () async -> Void

    package init(executableURL: URL, environment: [String: String], launch: ResolvedLanguageServerLaunch,
                 core: any LanguageServerRuntimeCore, release: @escaping @Sendable () async -> Void) {
        self.executableURL = executableURL
        self.environment = environment
        self.launch = launch
        self.core = core
        self.release = release
    }
}

package typealias WorkspaceLanguageServerSessionFactory = @MainActor (
    LanguageServerLaunchDescriptor, URL
) -> (any LanguageServerSession)?

/// Resolves a declarative launch for one workspace root. It runs when the
/// session starts, because the workspace state directory depends on the root.
package typealias LanguageServerLaunchResolver = @MainActor (
    DeclarativeLanguageServerLaunchSource,
    URL
) throws -> ResolvedLanguageServerLaunch

@MainActor
package final class StdioLanguageProviderRuntime: LanguageProviderRuntime {
    package let descriptor: LanguageProviderDescriptor
    private let runtimeService: any LanguageToolRuntimePort
    private let languageServerLaunch: LanguageServerLaunchDescriptor?
    private let languageServerCore: any LanguageServerRuntimeCore
    private let languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let hostIntegrationResolver: LanguageServerHostIntegrationResolver?
    private let languageServerLaunchResolver: LanguageServerLaunchResolver?
    private let languageServerCacheDirectory: URL?
    private let workspaceSessionFactory: WorkspaceLanguageServerSessionFactory?
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    private let moduleID: ModuleID
    private var runtimeUnavailableMessage: String?

    package var supportsLanguageServerSession: Bool {
        languageServerLaunch != nil
    }

    package var unavailableToolingMessage: String? {
        if let runtimeUnavailableMessage { return runtimeUnavailableMessage }
        guard let command = languageServerLaunch?.executableNames.first else { return nil }
        return runtimeService.missingLanguageToolMessage(command)
    }

    package init(
        descriptor: LanguageProviderDescriptor,
        runtimeService: any LanguageToolRuntimePort,
        languageServerLaunch: LanguageServerLaunchDescriptor? = nil,
        languageServerCore: any LanguageServerRuntimeCore,
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        hostIntegrationResolver: LanguageServerHostIntegrationResolver? = nil,
        languageServerLaunchResolver: LanguageServerLaunchResolver? = nil,
        languageServerCacheDirectory: URL? = nil,
        workspaceSessionFactory: WorkspaceLanguageServerSessionFactory? = nil,
        processRegistry: (any LanguageServerProcessRegistry)? = nil,
        moduleID: ModuleID = .languageIntelligence
    ) {
        self.descriptor = descriptor
        self.runtimeService = runtimeService
        self.languageServerLaunch = languageServerLaunch
        self.languageServerCore = languageServerCore
        self.languageServerExecutableResolver = languageServerExecutableResolver
        self.hostIntegrationResolver = hostIntegrationResolver
        self.languageServerLaunchResolver = languageServerLaunchResolver
        self.languageServerCacheDirectory = languageServerCacheDirectory
        self.workspaceSessionFactory = workspaceSessionFactory
        self.processRegistry = processRegistry
        self.moduleID = moduleID
    }

    package func makeLanguageServerSession() -> (any LanguageServerSession)? {
        runtimeUnavailableMessage = nil
        guard let languageServerLaunch else { return nil }
        let executableURL = if let languageServerExecutableResolver {
            languageServerExecutableResolver(descriptor)
        } else if let pinned = languageServerLaunch.executableURL {
            runtimeService.executableURL(at: pinned.path)
        } else {
            languageServerLaunch.executableNames.lazy.compactMap({
                self.runtimeService.executableOnPath($0)
            }).first
        }
        guard let executableURL else { return nil }
        let hostIntegrationLaunch: LanguageServerHostIntegrationLaunch?
        switch hostIntegrationResolver?(descriptor) {
        case nil:
            hostIntegrationLaunch = nil
        case .available(let launch):
            hostIntegrationLaunch = launch
        case .unavailable(let message):
            runtimeUnavailableMessage = message
            return nil
        }
        var environment = runtimeService.languageToolProcessEnvironment(
            runtimeTools: languageServerLaunch.runtimeTools
        )
        // A host integration owns the environment of its server. Any other
        // server started by a runtime gets the runtime selected above, not
        // another one the inherited PATH may list first.
        if let tool = languageServerLaunch.launchRuntimeTool, hostIntegrationLaunch == nil {
            environment = LanguageToolEnvironment.exportingRuntime(
                tool: tool,
                executableURL: executableURL,
                into: environment
            )
        }
        environment.merge(languageServerLaunch.environment) { _, configured in configured }
        let launchResolver: (@MainActor (URL) throws -> ResolvedLanguageServerLaunch)?
        if let source = languageServerLaunch.launchSource {
            // The declared arguments are templates. Without a resolver they
            // would reach the process unexpanded, so the server is unavailable.
            guard let languageServerLaunchResolver else {
                runtimeUnavailableMessage = "\(descriptor.displayName) needs a launch plan this build of Lithe cannot resolve."
                return nil
            }
            launchResolver = { rootURL in try languageServerLaunchResolver(source, rootURL) }
        } else {
            launchResolver = nil
        }
        return LanguageServerRuntimeSession(
            providerID: descriptor.id,
            executableURL: executableURL,
            arguments: languageServerLaunch.arguments,
            environment: environment,
            initializationOptions: languageServerLaunch.initializationOptions,
            launchResolver: launchResolver,
            hostIntegrationLaunch: hostIntegrationLaunch,
            cacheDirectoryURL: languageServerCacheDirectory,
            core: languageServerCore,
            processRegistry: processRegistry,
            moduleID: moduleID,
            pluginID: languageServerLaunch.launchSource?.pluginID
        )
    }

    package func makeLanguageServerSession(rootURL: URL) -> (any LanguageServerSession)? {
        if languageServerCore.requiresBackgroundLanguageServerStart(rootURL: rootURL),
           let workspaceSessionFactory, let languageServerLaunch {
            return workspaceSessionFactory(languageServerLaunch, rootURL)
        }
        return makeLanguageServerSession()
    }

}

@MainActor
package final class StdioLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
    private let runtimeService: any LanguageToolRuntimePort
    private let languageServerCore: any LanguageServerRuntimeCore
    private let languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let hostIntegrationResolver: LanguageServerHostIntegrationResolver?
    private let languageServerLaunchResolver: LanguageServerLaunchResolver?
    private let languageServerCacheDirectory: URL?
    private let workspaceSessionFactory: WorkspaceLanguageServerSessionFactory?
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    private let moduleID: ModuleID

    package init(
        runtimeService: any LanguageToolRuntimePort,
        languageServerCore: any LanguageServerRuntimeCore,
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        hostIntegrationResolver: LanguageServerHostIntegrationResolver? = nil,
        languageServerLaunchResolver: LanguageServerLaunchResolver? = nil,
        languageServerCacheDirectory: URL? = nil,
        workspaceSessionFactory: WorkspaceLanguageServerSessionFactory? = nil,
        processRegistry: (any LanguageServerProcessRegistry)? = nil,
        moduleID: ModuleID = .languageIntelligence
    ) {
        self.runtimeService = runtimeService
        self.languageServerCore = languageServerCore
        self.languageServerExecutableResolver = languageServerExecutableResolver
        self.hostIntegrationResolver = hostIntegrationResolver
        self.languageServerLaunchResolver = languageServerLaunchResolver
        self.languageServerCacheDirectory = languageServerCacheDirectory
        self.workspaceSessionFactory = workspaceSessionFactory
        self.processRegistry = processRegistry
        self.moduleID = moduleID
    }

    package func makeRuntime(
        for descriptor: LanguageProviderDescriptor
    ) -> (any LanguageProviderRuntime)? {
        let languageServerLaunch = descriptor.capabilities.contains(.languageServer)
            ? descriptor.languageServerLaunch
            : nil
        guard languageServerLaunch != nil else { return nil }
        return StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            languageServerLaunch: languageServerLaunch,
            languageServerCore: languageServerCore,
            languageServerExecutableResolver: languageServerExecutableResolver,
            hostIntegrationResolver: hostIntegrationResolver,
            languageServerLaunchResolver: languageServerLaunchResolver,
            languageServerCacheDirectory: languageServerCacheDirectory,
            workspaceSessionFactory: workspaceSessionFactory,
            processRegistry: processRegistry,
            moduleID: moduleID
        )
    }

    package func makeRuntime(
        for descriptor: LanguageProviderDescriptor,
        languageServerLaunch: LanguageServerLaunchDescriptor,
        ownerModuleID: ModuleID
    ) -> (any LanguageProviderRuntime)? {
        StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            languageServerLaunch: languageServerLaunch,
            languageServerCore: languageServerCore,
            languageServerExecutableResolver: languageServerExecutableResolver,
            hostIntegrationResolver: hostIntegrationResolver,
            languageServerLaunchResolver: languageServerLaunchResolver,
            languageServerCacheDirectory: languageServerCacheDirectory,
            workspaceSessionFactory: workspaceSessionFactory,
            processRegistry: processRegistry,
            moduleID: ownerModuleID
        )
    }
}
