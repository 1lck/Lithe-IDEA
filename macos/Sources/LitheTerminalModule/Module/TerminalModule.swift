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
    private let workspaceTerminalFactory: (@MainActor (URL) -> any TerminalTransport)?
    private let shellDiscovery: @MainActor () -> [String]
    private let workspaceShellDiscovery: (@MainActor (URL) async throws -> [String]?)?
    private var capability: TerminalModuleCapability?

    public init(
        terminalFactory: @escaping @MainActor () -> any TerminalTransport,
        workspaceTerminalFactory: (@MainActor (URL) -> any TerminalTransport)? = nil,
        shellDiscovery: @escaping @MainActor () -> [String] = { [] },
        workspaceShellDiscovery: (@MainActor (URL) async throws -> [String]?)? = nil
    ) {
        self.terminalFactory = terminalFactory
        self.workspaceTerminalFactory = workspaceTerminalFactory
        self.shellDiscovery = shellDiscovery
        self.workspaceShellDiscovery = workspaceShellDiscovery
    }

    public func activate(context: ModuleContext) async throws {
        guard capability == nil else { return }
        let feature = TerminalFeatureModel(
            terminalFactory: terminalFactory,
            workspaceTerminalFactory: workspaceTerminalFactory,
            shellDiscovery: shellDiscovery,
            workspaceShellDiscovery: workspaceShellDiscovery
        )
        let resource = TerminalSessionResource(feature: feature)
        context.resources.register(resource)
        capability = TerminalModuleCapability(feature: feature)
    }

    public func prepareForSleep() async throws {
        guard capability?.feature.hasActiveSessions != true else {
            throw TerminalModuleSleepError.runningSession
        }
    }

    public func sleep() async { await releaseFeature() }
    public func shutdown() async { await releaseFeature() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [.terminalWorkspace: capability]
    }

    public func contributions() -> [ModuleContribution] {
        Self.moduleContributions
    }

    private func releaseFeature() async {
        let feature = capability?.feature
        capability = nil
        // Application quit waits here, so terminal jobs in their own process
        // groups are gone before the process exits.
        await feature?.stopAllSessionsAndWait()
    }
}

public enum TerminalModuleSleepError: LocalizedError, Sendable {
    case runningSession
    public var errorDescription: String? { L10n.string("A terminal session is still running.") }
}

@MainActor
private final class TerminalSessionResource: ModuleResource {
    let feature: TerminalFeatureModel
    init(feature: TerminalFeatureModel) { self.feature = feature }
    var moduleResourceKind: String { "terminal-sessions" }
    var isModuleResourceActive: Bool { feature.hasActiveSessions }
    func stopModuleResource() async { await feature.stopAllSessionsAndWait() }
}
