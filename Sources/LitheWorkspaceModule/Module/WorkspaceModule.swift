import Foundation
import LitheModuleAPI

@MainActor
package protocol WorkspaceResourceGraph: AnyObject {
    var hasActiveResources: Bool { get }
    var feature: WorkspaceFeatureModel? { get }
    func attach(workspaceProjection: WorkspaceFeatureModel)
    func stop() async
}

@MainActor
public final class WorkspaceFoundationCapability: NSObject {
    private let graph: any WorkspaceResourceGraph
    fileprivate init(graph: any WorkspaceResourceGraph) { self.graph = graph }
    package var feature: WorkspaceFeatureModel? { graph.feature }
    package func attach(workspaceProjection: WorkspaceFeatureModel) {
        graph.attach(workspaceProjection: workspaceProjection)
    }
}

@MainActor
public final class WorkspaceFoundationModule: LitheModule {
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .workspace)!
    public let manifest = moduleManifest
    private let makeGraph: @MainActor () -> any WorkspaceResourceGraph
    private var graph: (any WorkspaceResourceGraph)?
    private var capability: WorkspaceFoundationCapability?

    package init(makeGraph: @escaping @MainActor () -> any WorkspaceResourceGraph) { self.makeGraph = makeGraph }
    public func activate(context: ModuleContext) async throws {
        guard graph == nil else { return }
        let graph = makeGraph()
        context.resources.register(WorkspaceGraphResource(graph: graph))
        self.graph = graph
        capability = WorkspaceFoundationCapability(graph: graph)
    }
    public func prepareForSleep() async throws {}
    public func sleep() async { await releaseGraph() }
    public func shutdown() async { await releaseGraph() }
    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.workspaceFoundation: capability]
    }
    private func releaseGraph() async {
        await graph?.stop()
        capability = nil
        graph = nil
    }
}

@MainActor private final class WorkspaceGraphResource: ModuleResource {
    let moduleResourceKind = "workspace-watchers-and-tasks"
    private let graph: any WorkspaceResourceGraph
    init(graph: any WorkspaceResourceGraph) { self.graph = graph }
    var isModuleResourceActive: Bool { graph.hasActiveResources }
    func stopModuleResource() async { await graph.stop() }
}
