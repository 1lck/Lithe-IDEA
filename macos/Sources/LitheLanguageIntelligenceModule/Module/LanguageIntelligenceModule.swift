import Foundation
import LitheModuleAPI

/// The temporary host-facing seam used while the concrete language services
/// are being moved into this target. Unlike `FeatureModuleHandle`, this seam is
/// language-specific and cannot host an arbitrary application object.
///
/// The module is the sole strong owner of the graph. Implementations must stop
/// every language-server session and polling task before `stop()` returns.
@MainActor
package protocol LanguageIntelligenceServiceGraph: AnyObject {
    var sessions: LanguageToolingSessionManager { get }
    var tools: LanguageServerToolService { get }
    var hasActiveLanguageServers: Bool { get }

    func activate(context: ModuleContext)
    func prepareForSleep() async throws
    func stop() async
}

@MainActor
public final class LanguageIntelligenceCapability: NSObject {
    package let sessions: LanguageToolingSessionManager
    package let tools: LanguageServerToolService

    fileprivate init(graph: any LanguageIntelligenceServiceGraph) {
        sessions = graph.sessions
        tools = graph.tools
    }
}

@MainActor
public final class LanguageIntelligenceModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .languageIntelligence)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .languageIntelligence)!

    public let manifest = moduleManifest

    private let makeGraph: @MainActor () -> any LanguageIntelligenceServiceGraph
    private var graph: (any LanguageIntelligenceServiceGraph)?
    private var capability: LanguageIntelligenceCapability?

    package init(
        makeGraph: @escaping @MainActor () -> any LanguageIntelligenceServiceGraph
    ) {
        self.makeGraph = makeGraph
    }

    public func activate(context: ModuleContext) async throws {
        guard graph == nil else { return }

        let graph = makeGraph()
        graph.activate(context: context)
        let resource = LanguageIntelligenceGraphResource(graph: graph)
        context.resources.register(resource)
        self.graph = graph
        capability = LanguageIntelligenceCapability(graph: graph)
    }

    public func prepareForSleep() async throws {
        try await graph?.prepareForSleep()
    }

    public func sleep() async {
        await releaseGraph()
    }

    public func shutdown() async {
        await releaseGraph()
    }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.languageIntelligence: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    private func releaseGraph() async {
        await graph?.stop()
        capability = nil
        graph = nil
    }
}

@MainActor
private final class LanguageIntelligenceGraphResource: ModuleResource {
    let moduleResourceKind = "language-intelligence-sessions"
    private let graph: any LanguageIntelligenceServiceGraph

    init(graph: any LanguageIntelligenceServiceGraph) {
        self.graph = graph
    }

    var isModuleResourceActive: Bool {
        graph.hasActiveLanguageServers
    }

    func stopModuleResource() async {
        await graph.stop()
    }
}
