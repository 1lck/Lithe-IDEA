import Foundation
import LitheModuleAPI

@MainActor
public protocol JavaDebugFeatureTarget: AnyObject {}

@MainActor
public protocol GenericDebugFeatureTarget: AnyObject {}

@MainActor
public protocol DebugServiceGraph: AnyObject {
    var javaFeatureTarget: any JavaDebugFeatureTarget { get }
    var genericFeatureTarget: any GenericDebugFeatureTarget { get }
    var hasActiveDebugWork: Bool { get }
    func activate(context: ModuleContext)
    func prepareForSleep() async throws
    func stop() async
}

@MainActor
public final class DebugModuleCapability: NSObject {
    public let javaFeature: any JavaDebugFeatureTarget
    public let genericFeature: any GenericDebugFeatureTarget

    fileprivate init(graph: any DebugServiceGraph) {
        javaFeature = graph.javaFeatureTarget
        genericFeature = graph.genericFeatureTarget
    }
}

@MainActor
public final class DebugModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .debug)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .debug)!
    public let manifest = moduleManifest
    private let makeGraph: @MainActor () -> any DebugServiceGraph
    private var graph: (any DebugServiceGraph)?
    private var capability: DebugModuleCapability?

    public init(makeGraph: @escaping @MainActor () -> any DebugServiceGraph) {
        self.makeGraph = makeGraph
    }

    public func activate(context: ModuleContext) async throws {
        guard graph == nil else { return }
        let graph = makeGraph()
        graph.activate(context: context)
        context.resources.register(DebugGraphResource(graph: graph))
        self.graph = graph
        capability = DebugModuleCapability(graph: graph)
    }

    public func prepareForSleep() async throws { try await graph?.prepareForSleep() }
    public func sleep() async { await releaseGraph() }
    public func shutdown() async { await releaseGraph() }
    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.debugWorkspace: capability]
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
private final class DebugGraphResource: ModuleResource {
    let moduleResourceKind = "debug-sessions"
    private let graph: any DebugServiceGraph
    init(graph: any DebugServiceGraph) { self.graph = graph }
    var isModuleResourceActive: Bool { graph.hasActiveDebugWork }
    func stopModuleResource() async { await graph.stop() }
}
