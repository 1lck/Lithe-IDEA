import Foundation
import LitheModuleAPI

/// Type-erased ownership boundary between a feature target and the app-specific
/// workflow object it hosts. The module target owns lifecycle and capability
/// publication; the composition root supplies the platform-independent feature
/// object and its narrowly scoped lifecycle callbacks.
@MainActor
public final class FeatureModuleHandle: @unchecked Sendable {
    public let value: AnyObject
    private let configureAction: @MainActor (ModuleContext) -> Void
    private let prepareAction: @MainActor () async throws -> Void
    private let stopAction: @MainActor () async -> Void
    private let resourceKind: String?
    private let resourceActive: @MainActor () -> Bool
    private var resourceID: UUID?
    private weak var resourceManager: (any ModuleResourceManaging)?

    public init(
        value: AnyObject,
        configure: @escaping @MainActor (ModuleContext) -> Void = { _ in },
        prepareForSleep: @escaping @MainActor () async throws -> Void = {},
        resourceKind: String? = nil,
        isResourceActive: @escaping @MainActor () -> Bool = { false },
        stop: @escaping @MainActor () async -> Void
    ) {
        self.value = value
        configureAction = configure
        prepareAction = prepareForSleep
        self.resourceKind = resourceKind
        resourceActive = isResourceActive
        stopAction = stop
    }

    public func configure(context: ModuleContext) {
        configureAction(context)
        if let resourceKind {
            resourceManager = context.resources
            resourceID = context.resources.register(
                HostedFeatureResource(kind: resourceKind, isActive: resourceActive, stop: stopAction)
            )
        }
    }

    public func prepareForSleep() async throws {
        try await prepareAction()
    }

    public func stop() async {
        await stopAction()
        if let resourceID {
            resourceManager?.unregisterResource(id: resourceID)
        }
        resourceID = nil
        resourceManager = nil
    }
}

@MainActor
private final class HostedFeatureResource: ModuleResource {
    let moduleResourceKind: String
    private let activeAction: @MainActor () -> Bool
    private let stopAction: @MainActor () async -> Void

    init(
        kind: String,
        isActive: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () async -> Void
    ) {
        moduleResourceKind = kind
        activeAction = isActive
        stopAction = stop
    }

    var isModuleResourceActive: Bool { activeAction() }
    func stopModuleResource() async { await stopAction() }
}

/// Reusable lifecycle implementation for modules whose concrete feature graph
/// is supplied by the platform composition root through a `FeatureModuleHandle`.
/// Each feature target still declares its own manifest and capability type.
@MainActor
open class HostedFeatureModule: LitheModule {
    public let manifest: ModuleManifest
    private let capabilityID: ModuleCapabilityID
    private let makeHandle: @MainActor () -> FeatureModuleHandle
    private let makeCapability: @MainActor (FeatureModuleHandle) -> AnyObject
    private var handle: FeatureModuleHandle?
    private var capability: AnyObject?

    public init(
        manifest: ModuleManifest,
        capabilityID: ModuleCapabilityID,
        makeHandle: @escaping @MainActor () -> FeatureModuleHandle,
        makeCapability: @escaping @MainActor (FeatureModuleHandle) -> AnyObject
    ) {
        self.manifest = manifest
        self.capabilityID = capabilityID
        self.makeHandle = makeHandle
        self.makeCapability = makeCapability
    }

    open func activate(context: ModuleContext) async throws {
        guard handle == nil else { return }
        let value = makeHandle()
        value.configure(context: context)
        handle = value
        capability = makeCapability(value)
    }

    open func prepareForSleep() async throws {
        try await handle?.prepareForSleep()
    }

    open func sleep() async {
        await handle?.stop()
        capability = nil
        handle = nil
    }

    open func shutdown() async {
        await handle?.stop()
        capability = nil
        handle = nil
    }

    open func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        guard let capability else { return [:] }
        return [capabilityID: capability]
    }

    open func contributions() -> [ModuleContribution] { [] }
}
