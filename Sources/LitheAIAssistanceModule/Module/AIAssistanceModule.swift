import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class AIAssistanceCapability: NSObject, AICommitMessageGenerating {
    private let service: CommitMessageGenerationService
    private weak var resources: (any ModuleResourceManaging)?
    private weak var leases: (any ModuleLeaseManaging)?

    init(service: CommitMessageGenerationService, resources: any ModuleResourceManaging, leases: any ModuleLeaseManaging) {
        self.service = service
        self.resources = resources
        self.leases = leases
    }

    public func generateCommitMessage(input: CommitMessageInput, settings: CommitMessageAISettings) async throws -> String {
        guard let resources, let leases else { throw CancellationError() }
        let task = Task { try await service.generate(input: input, settings: settings) }
        let resource = AIRequestResource(task: task)
        let resourceID = resources.register(resource)
        let lease = leases.acquireLease(reason: "Generating an AI commit message")
        defer {
            lease.release()
            resource.markCompleted()
            resources.unregisterResource(id: resourceID)
        }
        return try await task.value
    }
}

@MainActor
public final class AIAssistanceModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .aiAssistance)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .aiAssistance)!

    public let manifest = moduleManifest
    private let transportFactory: @MainActor () -> any AIHTTPTransport
    private let credentialResolver: any AIProviderCredentialResolver
    private var capability: AIAssistanceCapability?

    public init(
        transportFactory: @escaping @MainActor () -> any AIHTTPTransport,
        credentialResolver: any AIProviderCredentialResolver
    ) {
        self.transportFactory = transportFactory
        self.credentialResolver = credentialResolver
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        capability = AIAssistanceCapability(
            service: CommitMessageGenerationService(transport: transportFactory(), credentialResolver: credentialResolver),
            resources: context.resources,
            leases: context.leases
        )
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { capability = nil }
    public func shutdown() async { capability = nil }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.aiCommitMessage: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }
}

@MainActor
private final class AIRequestResource: ModuleResource {
    let task: Task<String, Error>
    private var isActive = true
    init(task: Task<String, Error>) { self.task = task }
    var moduleResourceKind: String { "ai-http-request" }
    var isModuleResourceActive: Bool { isActive }
    func markCompleted() { isActive = false }
    func stopModuleResource() async {
        task.cancel()
        _ = await task.result
        isActive = false
    }
}
