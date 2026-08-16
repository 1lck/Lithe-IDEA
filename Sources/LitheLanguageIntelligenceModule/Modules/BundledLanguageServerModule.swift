import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class BundledLanguageServerModule: LitheModule {
    public let manifest: ModuleManifest
    private let specification: BundledLanguagePluginSpecification
    private var capability: BundledLanguageServerCapability?

    public init(specification: BundledLanguagePluginSpecification) {
        self.specification = specification
        manifest = BundledLanguagePluginCatalog.manifests
            .flatMap(\.modules)
            .first { $0.manifest.id == .languageServerExtension(specification.id) }!
            .manifest
    }

    public func activate(context: ModuleContext) async throws {
        let lifecycle = BundledLanguageServerLifecycle()
        context.resources.register(BundledLanguageServerResource(lifecycle: lifecycle))
        capability = BundledLanguageServerCapability(specification: specification, lifecycle: lifecycle)
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { releaseCapability() }
    public func shutdown() async { releaseCapability() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.languageServerExtension(specification.id): $0] } ?? [:]
    }

    private func releaseCapability() {
        capability?.lifecycle.stop()
        capability = nil
    }
}

@MainActor
public final class BundledLanguageServerCapability: NSObject, LanguageServerExtensionProviding {
    public let configuration: LanguageServerExtensionConfiguration
    public let lifecycle: any LanguageServerExtensionLifecycle

    init(
        specification: BundledLanguagePluginSpecification,
        lifecycle: any LanguageServerExtensionLifecycle
    ) {
        configuration = LanguageServerExtensionConfiguration(
            languageID: specification.id,
            displayName: specification.displayName,
            executableNames: specification.executableNames,
            arguments: specification.arguments,
            validationArguments: specification.validationArguments,
            languageIdentifier: specification.languageIdentifier
        )
        self.lifecycle = lifecycle
    }
}

@MainActor
private final class BundledLanguageServerLifecycle: LanguageServerExtensionLifecycle {
    private var running: @MainActor () -> Bool = { false }
    private var stopAction: @MainActor () -> Void = {}

    var isRunning: Bool { running() }

    func attach(
        isRunning: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        running = isRunning
        stopAction = stop
    }

    func stop() { stopAction() }
}

@MainActor
private final class BundledLanguageServerResource: ModuleResource {
    let moduleResourceKind = "language-server-session"
    private let lifecycle: any LanguageServerExtensionLifecycle

    init(lifecycle: any LanguageServerExtensionLifecycle) {
        self.lifecycle = lifecycle
    }

    var isModuleResourceActive: Bool { lifecycle.isRunning }

    func stopModuleResource() async {
        lifecycle.stop()
        await lifecycle.waitUntilStopped()
    }
}
