import Foundation
import LitheModuleAPI

@MainActor
public final class GitModuleCapability: NSObject {
    package let feature: GitFeatureModel

    package init(feature: GitFeatureModel) {
        self.feature = feature
    }
}

@MainActor
public final class GitModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .git)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .git)!

    public let manifest = moduleManifest
    private let operations: any GitOperations
    private let shelfStorage: any GitShelfStorage
    private var capability: GitModuleCapability?

    package init(operations: any GitOperations, shelfStorage: any GitShelfStorage) {
        self.operations = operations
        self.shelfStorage = shelfStorage
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let feature = GitFeatureModel(
            service: GitService(operations: operations),
            shelveService: ShelveService(storage: shelfStorage)
        )
        feature.configureModuleLeases { reason in
            context.leases.acquireLease(reason: reason)
        }
        context.resources.register(GitFeatureResource(feature: feature))
        capability = GitModuleCapability(feature: feature)
    }

    public func prepareForSleep() async throws {
        guard capability?.feature.hasActiveModuleWork != true else {
            throw GitModuleSleepError.activeWork
        }
    }

    public func sleep() async { releaseFeature() }
    public func shutdown() async { releaseFeature() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.gitWorkspace: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    private func releaseFeature() {
        capability?.feature.reset()
        capability = nil
    }
}

public enum GitModuleSleepError: LocalizedError, Sendable {
    case activeWork

    public var errorDescription: String? { "Git work is still active." }
}

@MainActor
private final class GitFeatureResource: ModuleResource {
    let feature: GitFeatureModel

    init(feature: GitFeatureModel) {
        self.feature = feature
    }

    var moduleResourceKind: String { "git-feature-work" }
    var isModuleResourceActive: Bool { feature.hasActiveModuleWork }
    func stopModuleResource() async { feature.reset() }
}
