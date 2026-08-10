import Foundation

@MainActor
final class StdioLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    private let runtimeService: ProjectRuntimeService
    private let processFactory: () -> any RawProcessSession
    private let languageServerLaunch: LanguageServerLaunchDescriptor?
    private let languageServerCore: any LspClientCore
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
        languageServerCore: any LspClientCore = RustCoreBridge(),
        debugLaunch: StdioDebugAdapterLaunch? = nil,
        debugSessionFactory: (() -> (any DebugAdapterSession)?)? = nil
    ) {
        self.descriptor = descriptor
        self.runtimeService = runtimeService
        self.processFactory = processFactory
        self.languageServerLaunch = languageServerLaunch
        self.languageServerCore = languageServerCore
        self.debugLaunch = debugLaunch
        self.debugSessionFactory = debugSessionFactory
    }

    func makeLanguageServerSession() -> (any LanguageServerSession)? {
        guard let languageServerLaunch else { return nil }
        guard let executableURL = languageServerLaunch.executableNames.lazy.compactMap({
            self.runtimeService.executableOnPath($0)
        }).first else { return nil }
        return StdioLanguageServerSession(
            executableURL: executableURL,
            arguments: languageServerLaunch.arguments,
            environment: runtimeService.processEnvironment(),
            process: processFactory(),
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
                debugLaunch: pack.debugAdapterLaunch,
                debugSessionFactory: debugSessionFactories[pack.descriptor.id]
            )
        }
    }

    static func standard(
        catalog: LanguageProviderCatalog,
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        debugSessionFactories: [String: () -> (any DebugAdapterSession)?] = [:]
    ) -> [any LanguageProviderRuntime] {
        standard(
            packs: LanguagePackRegistry.standard(catalog: catalog).packs,
            runtimeService: runtimeService,
            processFactory: processFactory,
            debugSessionFactories: debugSessionFactories
        )
    }
}
