import Foundation

@MainActor
final class StdioLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    private let runtimeService: ProjectRuntimeService
    /// Kept for the debug adapter only: LSP transport lives in the Rust runtime.
    private let processFactory: () -> any RawProcessSession
    private let languageServerLaunch: LanguageServerLaunchDescriptor?
    private let languageServerCore: any LanguageServerRuntimeCore
    private let languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerCacheDirectory: URL?
    private let debugLaunch: StdioDebugAdapterLaunch?
    private let debugSessionFactory: (() -> (any DebugAdapterSession)?)?

    var supportsLanguageServerSession: Bool {
        languageServerLaunch != nil
    }

    var supportsDebugAdapterSession: Bool {
        debugLaunch != nil || debugSessionFactory != nil
    }

    var unavailableToolingMessage: String? {
        guard let command = languageServerLaunch?.executableNames.first
            ?? debugLaunch?.executableNames.first else { return nil }
        return runtimeService.missingToolMessage(command)
    }

    init(
        descriptor: LanguageProviderDescriptor,
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        languageServerLaunch: LanguageServerLaunchDescriptor? = nil,
        languageServerCore: any LanguageServerRuntimeCore = RustCoreBridge(),
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerCacheDirectory: URL? = nil,
        debugLaunch: StdioDebugAdapterLaunch? = nil,
        debugSessionFactory: (() -> (any DebugAdapterSession)?)? = nil
    ) {
        self.descriptor = descriptor
        self.runtimeService = runtimeService
        self.processFactory = processFactory
        self.languageServerLaunch = languageServerLaunch
        self.languageServerCore = languageServerCore
        self.languageServerExecutableResolver = languageServerExecutableResolver
        self.languageServerRuntimeResolver = languageServerRuntimeResolver
        self.languageServerCacheDirectory = languageServerCacheDirectory
        self.debugLaunch = debugLaunch
        self.debugSessionFactory = debugSessionFactory
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? {
        guard let languageServerLaunch else { return nil }
        let configuredExecutable = languageServerExecutableResolver?(descriptor)
        guard let executableURL = configuredExecutable
            ?? languageServerLaunch.executableNames.lazy.compactMap({
                self.runtimeService.executableOnPath($0)
            }).first else { return nil }
        var environment = runtimeService.processEnvironment()
        environment.merge(languageServerLaunch.environment) { _, configured in configured }
        return StdioLanguageServerSession(
            providerID: descriptor.id,
            executableURL: executableURL,
            arguments: languageServerLaunch.arguments,
            environment: environment,
            initializationOptions: languageServerLaunch.initializationOptions,
            runtimeExecutableURL: languageServerRuntimeResolver?(descriptor),
            cacheDirectoryURL: languageServerCacheDirectory,
            core: languageServerCore
        )
    }

    func makeDebugAdapterSession() -> (any DebugAdapterSession)? {
        if let debugSessionFactory { return debugSessionFactory() }
        guard let debugLaunch else { return nil }
        let direct = debugLaunch.executableNames.lazy.compactMap({ name in
            self.runtimeService.executableOnPath(name).map { ($0, debugLaunch.arguments) }
        }).first
        let fallback = debugLaunch.fallbacks.lazy.compactMap { fallback in
            self.runtimeService.executableOnPath(fallback.executableName).map {
                ($0, fallback.argumentPrefix + debugLaunch.arguments)
            }
        }.first
        guard let (executableURL, arguments) = direct ?? fallback else { return nil }
        return DebugAdapterProtocolSession(
            adapterID: debugLaunch.adapterID,
            executableURL: executableURL,
            arguments: arguments,
            environment: runtimeService.processEnvironment(),
            process: processFactory()
        )
    }

    static func standard(
        packs: [LanguagePack],
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerCacheDirectory: URL? = nil,
        debugSessionFactories: [String: () -> (any DebugAdapterSession)?] = [:]
    ) -> [any LanguageProviderRuntime] {
        packs.compactMap { pack in
            let hasLanguageServer = pack.descriptor.capabilities.contains(.languageServer)
                && pack.descriptor.languageServerLaunch != nil
            let hasDebugAdapter = pack.descriptor.capabilities.contains(.debugAdapter)
                && (pack.debugAdapterLaunch != nil || debugSessionFactories[pack.descriptor.id] != nil)
            guard hasLanguageServer || hasDebugAdapter else { return nil }
            return StdioLanguageProviderRuntime(
                descriptor: pack.descriptor,
                runtimeService: runtimeService,
                processFactory: processFactory,
                languageServerLaunch: pack.descriptor.languageServerLaunch,
                languageServerExecutableResolver: languageServerExecutableResolver,
                languageServerRuntimeResolver: languageServerRuntimeResolver,
                languageServerCacheDirectory: languageServerCacheDirectory,
                debugLaunch: pack.debugAdapterLaunch,
                debugSessionFactory: debugSessionFactories[pack.descriptor.id]
            )
        }
    }

    static func standard(
        catalog: LanguageProviderCatalog,
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerCacheDirectory: URL? = nil,
        debugSessionFactories: [String: () -> (any DebugAdapterSession)?] = [:]
    ) -> [any LanguageProviderRuntime] {
        standard(
            packs: LanguagePackRegistry.standard(catalog: catalog).packs,
            runtimeService: runtimeService,
            processFactory: processFactory,
            languageServerExecutableResolver: languageServerExecutableResolver,
            languageServerRuntimeResolver: languageServerRuntimeResolver,
            languageServerCacheDirectory: languageServerCacheDirectory,
            debugSessionFactories: debugSessionFactories
        )
    }
}

@MainActor
final class StdioLanguageProviderRuntimeFactory: LanguageProviderRuntimeFactory {
    private let runtimeService: ProjectRuntimeService
    private let processFactory: () -> any RawProcessSession
    private let languageServerCore: any LanguageServerRuntimeCore
    private let languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)?
    private let languageServerCacheDirectory: URL?
    private let debugLaunches: [String: StdioDebugAdapterLaunch]
    private let debugSessionFactories: [String: () -> (any DebugAdapterSession)?]

    init(
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        languageServerCore: any LanguageServerRuntimeCore = RustCoreBridge(),
        languageServerExecutableResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerRuntimeResolver: ((LanguageProviderDescriptor) -> URL?)? = nil,
        languageServerCacheDirectory: URL? = nil,
        debugLaunches: [String: StdioDebugAdapterLaunch] = [:],
        debugSessionFactories: [String: () -> (any DebugAdapterSession)?] = [:]
    ) {
        self.runtimeService = runtimeService
        self.processFactory = processFactory
        self.languageServerCore = languageServerCore
        self.languageServerExecutableResolver = languageServerExecutableResolver
        self.languageServerRuntimeResolver = languageServerRuntimeResolver
        self.languageServerCacheDirectory = languageServerCacheDirectory
        self.debugLaunches = debugLaunches
        self.debugSessionFactories = debugSessionFactories
    }

    func makeRuntime(
        for descriptor: LanguageProviderDescriptor
    ) -> (any LanguageProviderRuntime)? {
        let languageServerLaunch = descriptor.capabilities.contains(.languageServer)
            ? descriptor.languageServerLaunch
            : nil
        let debugLaunch = descriptor.capabilities.contains(.debugAdapter)
            ? debugLaunches[descriptor.id]
            : nil
        let debugSessionFactory = descriptor.capabilities.contains(.debugAdapter)
            ? debugSessionFactories[descriptor.id]
            : nil
        guard languageServerLaunch != nil || debugLaunch != nil || debugSessionFactory != nil else {
            return nil
        }
        return StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: runtimeService,
            processFactory: processFactory,
            languageServerLaunch: languageServerLaunch,
            languageServerCore: languageServerCore,
            languageServerExecutableResolver: languageServerExecutableResolver,
            languageServerRuntimeResolver: languageServerRuntimeResolver,
            languageServerCacheDirectory: languageServerCacheDirectory,
            debugLaunch: debugLaunch,
            debugSessionFactory: debugSessionFactory
        )
    }
}
