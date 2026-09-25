import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class AgentConversationCapability: NSObject {
    public let feature: AgentConversationFeatureModel

    public init(feature: AgentConversationFeatureModel) {
        self.feature = feature
    }
}

/// Optional, on-demand ACP conversation capability.
@MainActor
public final class AgentConversationModule: LitheModule {
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .agentConversation)!
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .agentConversation)

    public let manifest = moduleManifest
    private let transportFactory: @MainActor () -> any AgentConversationTransport
    private var capability: AgentConversationCapability?

    public init(transportFactory: @escaping @MainActor () -> any AgentConversationTransport) {
        self.transportFactory = transportFactory
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let feature = AgentConversationFeatureModel(transport: transportFactory())
        context.resources.register(AgentSessionResource(feature: feature))
        capability = AgentConversationCapability(feature: feature)
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { await releaseFeature() }
    public func shutdown() async { await releaseFeature() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.agentConversation: capability]
    }

    public func contributions() -> [ModuleContribution] { Self.moduleContributions }

    private func releaseFeature() async {
        await capability?.feature.stop()
        capability = nil
    }
}

@MainActor
private final class AgentSessionResource: ModuleResource {
    let feature: AgentConversationFeatureModel
    init(feature: AgentConversationFeatureModel) { self.feature = feature }
    var moduleResourceKind: String { "acp-agent-session" }
    var isModuleResourceActive: Bool { feature.hasActiveSession }
    func stopModuleResource() async { await feature.stop() }
}
