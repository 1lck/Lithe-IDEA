import Foundation
import LitheCoreContracts
import LitheDebugModule

/// Creates DAP sessions for the Debug module without constructing or retaining
/// a language-server runtime. Provider descriptors remain shared catalog data;
/// the adapter process and session are owned exclusively by Debug.
@MainActor
final class DebugAdapterRuntimeFactory {
    private let runtimeService: ProjectRuntimeService
    private let transportFactory: (URL, [String], [String: String]) -> any DebugAdapterTransport
    private let launches: [String: StdioDebugAdapterLaunch]
    private let sessionFactories: [String: () -> (any DebugAdapterSession)?]

    init(
        runtimeService: ProjectRuntimeService,
        transportFactory: @escaping (URL, [String], [String: String]) -> any DebugAdapterTransport,
        launches: [String: StdioDebugAdapterLaunch],
        sessionFactories: [String: () -> (any DebugAdapterSession)?] = [:]
    ) {
        self.runtimeService = runtimeService
        self.transportFactory = transportFactory
        self.launches = launches
        self.sessionFactories = sessionFactories
    }

    func makeSession(
        for descriptor: DebugProviderDescriptor,
        rootURL _: URL
    ) -> (any DebugAdapterSession)? {
        if let sessionFactory = sessionFactories[descriptor.id] {
            return sessionFactory()
        }
        guard let launch = launches[descriptor.id] else { return nil }

        let direct = launch.executableNames.lazy.compactMap { name in
            self.runtimeService.executableOnPath(name).map { ($0, launch.arguments) }
        }.first
        let fallback = launch.fallbacks.lazy.compactMap { fallback in
            self.runtimeService.executableOnPath(fallback.executableName).map {
                ($0, fallback.argumentPrefix + launch.arguments)
            }
        }.first
        guard let (executableURL, arguments) = direct ?? fallback else { return nil }

        return DebugAdapterProtocolSession(
            adapterID: launch.adapterID,
            transport: transportFactory(
                executableURL,
                arguments,
                runtimeService.processEnvironment()
            )
        )
    }
}
