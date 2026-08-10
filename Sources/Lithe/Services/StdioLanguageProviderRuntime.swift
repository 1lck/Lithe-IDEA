import Foundation

@MainActor
final class StdioLanguageProviderRuntime: LanguageProviderRuntime {
    let descriptor: LanguageProviderDescriptor
    private let runtimeService: ProjectRuntimeService
    private let processFactory: () -> any RawProcessSession
    private let debugLaunch: StdioDebugAdapterLaunch?
    private let debugSessionFactory: (() -> (any DebugAdapterSession)?)?

    var supportsDebugAdapterSession: Bool {
        debugLaunch != nil || debugSessionFactory != nil
    }

    var unavailableToolingMessage: String? {
        guard let command = debugLaunch?.executableNames.first else { return nil }
        return runtimeService.missingToolMessage(command)
    }

    init(
        descriptor: LanguageProviderDescriptor,
        runtimeService: ProjectRuntimeService,
        processFactory: @escaping () -> any RawProcessSession,
        debugLaunch: StdioDebugAdapterLaunch? = nil,
        debugSessionFactory: (() -> (any DebugAdapterSession)?)? = nil
    ) {
        self.descriptor = descriptor
        self.runtimeService = runtimeService
        self.processFactory = processFactory
        self.debugLaunch = debugLaunch
        self.debugSessionFactory = debugSessionFactory
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
            guard pack.descriptor.capabilities.contains(.debugAdapter) else { return nil }
            guard pack.debugAdapterLaunch != nil || debugSessionFactories[pack.descriptor.id] != nil
            else { return nil }
            return StdioLanguageProviderRuntime(
                descriptor: pack.descriptor,
                runtimeService: runtimeService,
                processFactory: processFactory,
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
