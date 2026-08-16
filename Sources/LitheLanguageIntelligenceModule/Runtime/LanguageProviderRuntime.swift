import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
package final class StdioLanguageProviderRuntime: LanguageProviderRuntime {
    package let descriptor: LanguageProviderDescriptor
    private let runtimeService: any LanguageToolRuntimePort
    private let languageServerLaunch: LanguageServerLaunchDescriptor?
    private let languageServerCore: any LanguageServerRuntimeCore
    private let languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerCacheDirectory: URL?
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    private let moduleID: ModuleID

    package var supportsLanguageServerSession: Bool {
        languageServerLaunch != nil
    }

    package var unavailableToolingMessage: String? {
        guard let command = languageServerLaunch?.executableNames.first else { return nil }
        return runtimeService.missingLanguageToolMessage(command)
    }

    package init(
        descriptor: LanguageProviderDescriptor,
        runtimeService: any LanguageToolRuntimePort,
        languageServerLaunch: LanguageServerLaunchDescriptor? = nil,
        languageServerCore: any LanguageServerRuntimeCore,
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerCacheDirectory: URL? = nil,
        processRegistry: (any LanguageServerProcessRegistry)? = nil,
        moduleID: ModuleID = .languageIntelligence
    ) {
        self.descriptor = descriptor
        self.runtimeService = runtimeService
        self.languageServerLaunch = languageServerLaunch
        self.languageServerCore = languageServerCore
        self.languageServerExecutableResolver = languageServerExecutableResolver
        self.languageServerRuntimeResolver = languageServerRuntimeResolver
        self.languageServerCacheDirectory = languageServerCacheDirectory
        self.processRegistry = processRegistry
        self.moduleID = moduleID
    }

    package func makeLanguageServerSession() -> (any LanguageServerSession)? {
        guard let languageServerLaunch else { return nil }
        let executableURL = if let languageServerExecutableResolver {
            languageServerExecutableResolver(descriptor)
        } else {
            languageServerLaunch.executableNames.lazy.compactMap({
                self.runtimeService.executableOnPath($0)
            }).first
        }
        guard let executableURL else { return nil }
        var environment = runtimeService.languageToolProcessEnvironment()
        environment.merge(languageServerLaunch.environment) { _, configured in configured }
        return LanguageServerRuntimeSession(
            providerID: descriptor.id,
            executableURL: executableURL,
            arguments: languageServerLaunch.arguments,
            environment: environment,
            initializationOptions: languageServerLaunch.initializationOptions,
            runtimeExecutableURL: languageServerRuntimeResolver?(descriptor),
            cacheDirectoryURL: languageServerCacheDirectory,
            core: languageServerCore,
            processRegistry: processRegistry,
            moduleID: moduleID
        )
    }

}

@MainActor
package final class StdioLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
    private let runtimeService: any LanguageToolRuntimePort
    private let languageServerCore: any LanguageServerRuntimeCore
    private let languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerCacheDirectory: URL?
    private weak var processRegistry: (any LanguageServerProcessRegistry)?
    private let moduleID: ModuleID

    package init(
        runtimeService: any LanguageToolRuntimePort,
        languageServerCore: any LanguageServerRuntimeCore,
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerCacheDirectory: URL? = nil,
        processRegistry: (any LanguageServerProcessRegistry)? = nil,
        moduleID: ModuleID = .languageIntelligence
    ) {
        self.runtimeService = runtimeService
        self.languageServerCore = languageServerCore
        self.languageServerExecutableResolver = languageServerExecutableResolver
        self.languageServerRuntimeResolver = languageServerRuntimeResolver
        self.languageServerCacheDirectory = languageServerCacheDirectory
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
            languageServerRuntimeResolver: languageServerRuntimeResolver,
            languageServerCacheDirectory: languageServerCacheDirectory,
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
            languageServerRuntimeResolver: languageServerRuntimeResolver,
            languageServerCacheDirectory: languageServerCacheDirectory,
            processRegistry: processRegistry,
            moduleID: ownerModuleID
        )
    }
}
