import Foundation

@MainActor
public protocol ModuleCapabilityResolver: AnyObject {
    func capability(_ id: ModuleCapabilityID) -> AnyObject?
}

@MainActor
public protocol ModuleEventPublishing: AnyObject {
    func publish(_ event: ModuleEvent)
}

@MainActor
public protocol ModuleContributionPublishing: AnyObject {
    func register(_ contribution: ModuleContribution, for moduleID: ModuleID)
    func removeContributions(for moduleID: ModuleID)
    func contributions() -> [ModuleID: [ModuleContribution]]
}

public protocol ModuleConfigurationStore: Sendable {
    func enabledState(for moduleID: ModuleID) -> Bool?
    func setEnabledState(_ enabled: Bool, for moduleID: ModuleID)
}

/// Durable recovery metadata that is readable without constructing a module.
/// A pending activation left behind by a terminated process is quarantined on
/// the next launch, allowing the app shell to start without loading its code.
public protocol ModuleRecoveryStore: Sendable {
    func pendingActivation() -> ModuleID?
    func setPendingActivation(_ moduleID: ModuleID?)
    func pendingActivations() -> [ModuleID]
    func setPendingActivations(_ moduleIDs: [ModuleID])
    func isQuarantined(_ moduleID: ModuleID) -> Bool
    func setQuarantined(_ quarantined: Bool, for moduleID: ModuleID)
    func pendingPluginLoadModules() -> [ModuleID]
    func setPendingPluginLoadModules(_ moduleIDs: [ModuleID])
}

public extension ModuleRecoveryStore {
    func pendingActivations() -> [ModuleID] {
        pendingActivation().map { [$0] } ?? []
    }
    func setPendingActivations(_ moduleIDs: [ModuleID]) {
        setPendingActivation(moduleIDs.sorted().first)
    }
    func pendingPluginLoadModules() -> [ModuleID] { [] }
    func setPendingPluginLoadModules(_ moduleIDs: [ModuleID]) {}
}

public struct ModuleEvent: Equatable, Sendable {
    public let source: ModuleID
    public let name: String
    public let attributes: [String: String]

    public init(source: ModuleID, name: String, attributes: [String: String] = [:]) {
        self.source = source
        self.name = name
        self.attributes = attributes
    }
}

/// Swift entrypoint for same-team official plugins built against the matching
/// Plugin API and host compatibility range. Static manifest validation and
/// enablement checks must happen before the bundle containing this type loads.
@MainActor
public protocol LithePluginEntrypoint: AnyObject {
    init()
    func moduleFactories(context: PluginHostContext) throws -> [ModuleFactory]
}

public struct PluginHostServiceID: RawRepresentable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "A plugin host service ID must not be empty.")
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

@MainActor
public protocol PluginHostServiceResolving: AnyObject {
    func service(_ id: PluginHostServiceID) -> AnyObject?
}

/// Read-only services supplied by the host while a plugin creates its lazy
/// module factories. Plugins request narrow, versioned service protocols by
/// ID instead of importing platform adapters or the application executable.
@MainActor
public struct PluginHostContext {
    private let resolver: any PluginHostServiceResolving

    public init(resolver: any PluginHostServiceResolving) {
        self.resolver = resolver
    }

    public func service(_ id: PluginHostServiceID) -> AnyObject? {
        resolver.service(id)
    }

    public static var empty: PluginHostContext {
        PluginHostContext(resolver: EmptyPluginHostServiceResolver.shared)
    }
}

@MainActor
private final class EmptyPluginHostServiceResolver: PluginHostServiceResolving {
    static let shared = EmptyPluginHostServiceResolver()
    func service(_ id: PluginHostServiceID) -> AnyObject? { nil }
}

public extension ModuleEvent {
    static let stateChangedName = "module.state-changed"
    static let activityStartedName = "module.activity-started"
    static let activityEndedName = "module.activity-ended"
}

@MainActor
public protocol ModuleResource: AnyObject {
    var moduleResourceKind: String { get }
    var isModuleResourceActive: Bool { get }
    func stopModuleResource() async
}

public struct ModuleResourceSnapshot: Equatable, Sendable {
    public let id: UUID
    public let kind: String
    public let isActive: Bool

    public init(id: UUID, kind: String, isActive: Bool) {
        self.id = id
        self.kind = kind
        self.isActive = isActive
    }
}

@MainActor
public protocol ModuleResourceManaging: AnyObject {
    @discardableResult
    func register(_ resource: any ModuleResource) -> UUID
    func unregisterResource(id: UUID)
    func resourceSnapshots() -> [ModuleResourceSnapshot]
}

@MainActor
public protocol ModuleLeaseManaging: AnyObject {
    func acquireLease(reason: String) -> ModuleLease
}

@MainActor
public final class ModuleLease {
    public let id: UUID
    public let reason: String
    private let releaseAction: @MainActor (UUID) -> Void
    private var isReleased = false

    public init(
        id: UUID = UUID(),
        reason: String,
        releaseAction: @escaping @MainActor (UUID) -> Void
    ) {
        self.id = id
        self.reason = reason
        self.releaseAction = releaseAction
    }

    public func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseAction(id)
    }

    deinit {
        if !isReleased {
            let id = id
            let releaseAction = releaseAction
            Task { @MainActor in releaseAction(id) }
        }
    }
}

@MainActor
public struct ModuleContext {
    public let moduleID: ModuleID
    public let workspaceURL: URL?
    public let capabilities: any ModuleCapabilityResolver
    public let events: any ModuleEventPublishing
    public let resources: any ModuleResourceManaging
    public let leases: any ModuleLeaseManaging
    public let contributions: any ModuleContributionPublishing

    public init(
        moduleID: ModuleID,
        workspaceURL: URL?,
        capabilities: any ModuleCapabilityResolver,
        events: any ModuleEventPublishing,
        resources: any ModuleResourceManaging,
        leases: any ModuleLeaseManaging
        , contributions: any ModuleContributionPublishing
    ) {
        self.moduleID = moduleID
        self.workspaceURL = workspaceURL
        self.capabilities = capabilities
        self.events = events
        self.resources = resources
        self.leases = leases
        self.contributions = contributions
    }
}

@MainActor
public protocol LitheModule: AnyObject {
    var manifest: ModuleManifest { get }
    func activate(context: ModuleContext) async throws
    func prepareForSleep() async throws
    func sleep() async
    func shutdown() async
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject]
    func contributions() -> [ModuleContribution]
}

public extension LitheModule {
    func contributions() -> [ModuleContribution] { [] }
}

@MainActor
public struct ModuleFactory {
    public let manifest: ModuleManifest
    public let contributions: [ModuleContribution]
    private let makeAction: @MainActor () throws -> any LitheModule

    public init(
        manifest: ModuleManifest,
        contributions: [ModuleContribution] = [],
        make: @escaping @MainActor () throws -> any LitheModule
    ) {
        self.manifest = manifest
        self.contributions = contributions.sorted {
            ($0.placement.rawValue, $0.order, $0.id)
                < ($1.placement.rawValue, $1.order, $1.id)
        }
        self.makeAction = make
    }

    public func makeModule() throws -> any LitheModule {
        try makeAction()
    }
}

public enum ModuleRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case duplicateModule(ModuleID)
    case unknownModule(ModuleID)
    case dependencyCycle([ModuleID])
    case missingModuleDependency(module: ModuleID, dependency: ModuleID)
    case missingCapabilityDependency(module: ModuleID, capability: ModuleCapabilityID)
    case capabilityCollision(capability: ModuleCapabilityID, providers: [ModuleID])
    case missingExportedCapability(module: ModuleID, capability: ModuleCapabilityID)
    case undeclaredExportedCapability(module: ModuleID, capability: ModuleCapabilityID)
    case contributionCatalogMismatch(ModuleID)
    case builtInManifestMismatch(ModuleID)
    case moduleDisabled(ModuleID)
    case moduleQuarantined(ModuleID)
    case optionalModuleUnavailableInSafeMode(ModuleID)
    case requiredModuleCannotBeDisabled(ModuleID)
    case enabledDependentsPreventDisable(module: ModuleID, dependents: [ModuleID])
    case activeDependentsPreventSleep(module: ModuleID, dependents: [ModuleID])
    case activeLeasesPreventSleep(module: ModuleID, reasons: [String])
    case activeResourcesRemain(module: ModuleID, kinds: [String])

    public var errorDescription: String? {
        switch self {
        case .duplicateModule(let id): "Module \(id) is already registered."
        case .unknownModule(let id): "Module \(id) is not registered."
        case .dependencyCycle(let ids): "Module dependency cycle: \(ids.map(\.rawValue).joined(separator: " -> "))."
        case .missingModuleDependency(let module, let dependency):
            "Module \(module) requires missing module \(dependency)."
        case .missingCapabilityDependency(let module, let capability):
            "Module \(module) requires missing capability \(capability)."
        case .capabilityCollision(let capability, let providers):
            "Capability \(capability) has multiple providers: \(providers.map(\.rawValue).joined(separator: ", "))."
        case .missingExportedCapability(let module, let capability):
            "Module \(module) did not export declared capability \(capability)."
        case .undeclaredExportedCapability(let module, let capability):
            "Module \(module) exported undeclared capability \(capability)."
        case .contributionCatalogMismatch(let module):
            "Module \(module) instance contributions differ from its static factory catalog."
        case .builtInManifestMismatch(let module):
            "Built-in module \(module) does not match the shared manifest catalog."
        case .moduleDisabled(let id): "Module \(id) is disabled."
        case .moduleQuarantined(let id):
            "Module \(id) was disabled because its previous activation did not complete. Re-enable it to try again."
        case .optionalModuleUnavailableInSafeMode(let id):
            "Module \(id) is unavailable while Lithe is running in Safe Mode."
        case .requiredModuleCannotBeDisabled(let id): "Required module \(id) cannot be disabled."
        case .enabledDependentsPreventDisable(let module, let dependents):
            "Module \(module) is required by enabled modules: \(dependents.map(\.rawValue).joined(separator: ", "))."
        case .activeDependentsPreventSleep(let module, let dependents):
            "Module \(module) cannot sleep while dependent modules are active: \(dependents.map(\.rawValue).joined(separator: ", "))."
        case .activeLeasesPreventSleep(let module, let reasons):
            "Module \(module) cannot sleep while active leases remain: \(reasons.joined(separator: ", "))."
        case .activeResourcesRemain(let module, let kinds):
            "Module \(module) still owns active resources after stopping: \(kinds.joined(separator: ", "))."
        }
    }
}
