import Foundation
import LitheModuleAPI

@MainActor
public final class TerminalModuleCapability: NSObject {
    public let feature: TerminalFeatureModel
    public init(feature: TerminalFeatureModel) { self.feature = feature }
}

@MainActor
public final class TerminalModule: LitheModule {
    public static let moduleContributions = BuiltInModuleCatalog.contributions(for: .terminal)
    public static let moduleManifest = BuiltInModuleCatalog.manifest(for: .terminal)!

    public let manifest = moduleManifest
    private let terminalFactory: @MainActor () -> any TerminalTransport
    private let shellDiscovery: @MainActor () -> [String]
    private var capability: TerminalModuleCapability?

    public init(
        terminalFactory: @escaping @MainActor () -> any TerminalTransport,
        shellDiscovery: @escaping @MainActor () -> [String] = { [] }
    ) {
        self.terminalFactory = terminalFactory
        self.shellDiscovery = shellDiscovery
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let feature = TerminalFeatureModel(
            terminalFactory: terminalFactory,
            shellDiscovery: shellDiscovery
        )
        let resource = TerminalSessionResource(feature: feature)
        context.resources.register(resource)
        capability = TerminalModuleCapability(feature: feature)
    }

    public func prepareForSleep() async throws {
        guard capability?.feature.terminalSessions.allSatisfy({ !$0.isRunning }) != false else {
            throw TerminalModuleSleepError.runningSession
        }
    }

    public func sleep() async { releaseFeature() }
    public func shutdown() async { releaseFeature() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.terminalWorkspace: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    private func releaseFeature() {
        capability?.feature.stopAllSessions()
        capability = nil
    }
}

public enum TerminalModuleSleepError: LocalizedError, Sendable {
    case runningSession
    public var errorDescription: String? { "A terminal session is still running." }
}

@MainActor
private final class TerminalSessionResource: ModuleResource {
    let feature: TerminalFeatureModel
    init(feature: TerminalFeatureModel) { self.feature = feature }
    var moduleResourceKind: String { "terminal-sessions" }
    var isModuleResourceActive: Bool { feature.terminalSessions.contains(where: \.isRunning) }
    func stopModuleResource() async { feature.stopAllSessions() }
}
