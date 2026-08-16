import Foundation
import LitheModuleAPI

@MainActor
package protocol ExecutionServiceGraph: AnyObject {
    var mavenFeature: MavenFeatureModel { get }
    var runFeature: RunFeatureModel { get }
    var tests: LanguageTestService { get }
    var projectDevelopment: ProjectDevelopmentFeatureModel { get }
    var hasActiveExecutionWork: Bool { get }
    func activate(context: ModuleContext)
    func prepareForSleep() async throws
    func stop() async
}

@MainActor
public final class ExecutionModuleCapability: NSObject {
    package let mavenFeature: MavenFeatureModel
    package let runFeature: RunFeatureModel
    package let testService: LanguageTestService
    package let projectDevelopment: ProjectDevelopmentFeatureModel
    fileprivate init(graph: any ExecutionServiceGraph) {
        mavenFeature = graph.mavenFeature
        runFeature = graph.runFeature
        testService = graph.tests
        projectDevelopment = graph.projectDevelopment
    }
}

@MainActor
public final class ExecutionModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .execution)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .execution)!
    public let manifest = moduleManifest
    private let makeGraph: @MainActor () -> any ExecutionServiceGraph
    private var graph: (any ExecutionServiceGraph)?
    private var capability: ExecutionModuleCapability?

    package init(makeGraph: @escaping @MainActor () -> any ExecutionServiceGraph) {
        self.makeGraph = makeGraph
    }

    public func activate(context: ModuleContext) async throws {
        guard graph == nil else { return }
        let graph = makeGraph()
        graph.activate(context: context)
        context.resources.register(ExecutionGraphResource(graph: graph))
        self.graph = graph
        capability = ExecutionModuleCapability(graph: graph)
    }
    public func prepareForSleep() async throws { try await graph?.prepareForSleep() }
    public func sleep() async { await releaseGraph() }
    public func shutdown() async { await releaseGraph() }
    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.executionWorkspace: capability]
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
private final class ExecutionGraphResource: ModuleResource {
    let moduleResourceKind = "execution-processes"
    private let graph: any ExecutionServiceGraph
    init(graph: any ExecutionServiceGraph) { self.graph = graph }
    var isModuleResourceActive: Bool { graph.hasActiveExecutionWork }
    func stopModuleResource() async { await graph.stop() }
}
