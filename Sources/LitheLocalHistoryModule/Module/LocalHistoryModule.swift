import Foundation
import LitheModuleAPI

@MainActor
public final class HistoryModuleCapability: NSObject {
    public let feature: ProjectHistoryFeatureModel
    public init(feature: ProjectHistoryFeatureModel) { self.feature = feature }
}

@MainActor
public final class HistoryModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .localHistory)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .localHistory)!

    public let manifest = moduleManifest
    private let workspaceAccess: any LocalHistoryWorkspaceAccess
    private let storage: any LocalHistoryStorage
    private let operations: any LocalHistoryOperations
    private var capability: HistoryModuleCapability?

    public init(workspaceAccess: any LocalHistoryWorkspaceAccess, storage: any LocalHistoryStorage, operations: any LocalHistoryOperations) {
        self.workspaceAccess = workspaceAccess
        self.storage = storage
        self.operations = operations
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let feature = ProjectHistoryFeatureModel(workspaceAccess: workspaceAccess, storage: storage, localHistoryOperations: operations)
        context.resources.register(HistoryTaskResource(feature: feature))
        capability = HistoryModuleCapability(feature: feature)
    }

    public func prepareForSleep() async throws {
        guard capability?.feature.hasActiveModuleWork != true else { throw HistoryModuleSleepError.activeWork }
    }
    public func sleep() async { releaseFeature() }
    public func shutdown() async { releaseFeature() }
    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.historyWorkspace: capability]
    }
    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    private func releaseFeature() {
        capability?.feature.reset()
        capability = nil
    }
}

public enum HistoryModuleSleepError: LocalizedError, Sendable {
    case activeWork
    public var errorDescription: String? { "Local history work is still active." }
}

@MainActor
private final class HistoryTaskResource: ModuleResource {
    let feature: ProjectHistoryFeatureModel
    init(feature: ProjectHistoryFeatureModel) { self.feature = feature }
    var moduleResourceKind: String { "local-history-tasks" }
    var isModuleResourceActive: Bool { feature.hasActiveModuleWork }
    func stopModuleResource() async { feature.reset() }
}
