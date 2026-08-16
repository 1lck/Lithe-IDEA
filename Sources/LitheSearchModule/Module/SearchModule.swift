import Foundation
import LitheModuleAPI

@MainActor
public final class SearchModuleCapability: NSObject {
    public let feature: SearchFeatureModel
    public init(feature: SearchFeatureModel) { self.feature = feature }
}

@MainActor
public final class SearchModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .search)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .search)!

    public let manifest = moduleManifest
    private let operations: any SearchOperations
    private var capability: SearchModuleCapability?

    public init(operations: any SearchOperations) {
        self.operations = operations
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let feature = SearchFeatureModel(operations: operations)
        context.resources.register(SearchTaskResource(feature: feature))
        capability = SearchModuleCapability(feature: feature)
    }

    public func prepareForSleep() async throws {
        guard capability?.feature.hasActiveModuleWork != true else {
            throw SearchModuleSleepError.activeSearch
        }
    }

    public func sleep() async { releaseFeature() }
    public func shutdown() async { releaseFeature() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.searchWorkspace: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    private func releaseFeature() {
        capability?.feature.reset()
        capability = nil
    }
}

public enum SearchModuleSleepError: LocalizedError, Sendable {
    case activeSearch
    public var errorDescription: String? { "Search or replacement work is still active." }
}

@MainActor
private final class SearchTaskResource: ModuleResource {
    let feature: SearchFeatureModel
    init(feature: SearchFeatureModel) { self.feature = feature }
    var moduleResourceKind: String { "search-tasks" }
    var isModuleResourceActive: Bool { feature.hasActiveModuleWork }
    func stopModuleResource() async { feature.reset() }
}
