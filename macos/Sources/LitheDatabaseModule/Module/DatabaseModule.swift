import Foundation
import LitheModuleAPI

@MainActor
public final class DatabaseModuleCapability: NSObject {
    package let feature: DatabaseFeatureModel
    package init(feature: DatabaseFeatureModel) { self.feature = feature }
}

@MainActor
public final class DatabaseModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .database)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .database)!

    public let manifest = moduleManifest
    private let processRunner: any DatabaseProcessRunning
    private let executableURL: URL?
    private let preferenceStore: any DatabasePreferenceStore
    private let secureStore: any DatabaseSecureStore
    private let recoveryStore: any DatabaseRecoveryStoring
    private let fileStorage: any DatabaseFileStorage
    private var capability: DatabaseModuleCapability?

    package init(
        processRunner: any DatabaseProcessRunning,
        executableURL: URL?,
        preferenceStore: any DatabasePreferenceStore,
        secureStore: any DatabaseSecureStore,
        recoveryStore: any DatabaseRecoveryStoring,
        fileStorage: any DatabaseFileStorage
    ) {
        self.processRunner = processRunner
        self.executableURL = executableURL
        self.preferenceStore = preferenceStore
        self.secureStore = secureStore
        self.recoveryStore = recoveryStore
        self.fileStorage = fileStorage
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let feature = DatabaseFeatureModel(
            operations: DatabaseSidecarService(processRunner: processRunner, executableURL: executableURL),
            connectionStore: DatabaseConnectionStore(store: preferenceStore, secureStore: secureStore),
            recoveryStore: recoveryStore,
            fileStorage: fileStorage
        )
        context.resources.register(DatabaseFeatureResource(feature: feature))
        capability = DatabaseModuleCapability(feature: feature)
    }

    public func prepareForSleep() async throws {
        guard capability?.feature.hasActiveModuleWork != true else { throw DatabaseModuleSleepError.activeWork }
    }

    public func sleep() async { releaseFeature() }
    public func shutdown() async { releaseFeature() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.databaseWorkspace: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    private func releaseFeature() {
        capability?.feature.prepareForModuleRelease()
        capability = nil
    }
}

public enum DatabaseModuleSleepError: LocalizedError, Sendable {
    case activeWork
    public var errorDescription: String? { "Database operations or scheduled backup work are still active." }
}

@MainActor
private final class DatabaseFeatureResource: ModuleResource {
    let feature: DatabaseFeatureModel
    init(feature: DatabaseFeatureModel) { self.feature = feature }
    var moduleResourceKind: String { "database-timer-and-operations" }
    var isModuleResourceActive: Bool { feature.hasActiveModuleWork }
    func stopModuleResource() async { feature.prepareForModuleRelease() }
}
