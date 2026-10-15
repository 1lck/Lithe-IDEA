import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Host-owned language-server module. The host launches and stops the server
/// process itself; the module only publishes its launch configuration, so it
/// serves bundled language specifications and declarative plugins alike.
@MainActor
public final class BundledLanguageServerModule: LitheModule {
    public let manifest: ModuleManifest
    private let configuration: LanguageServerExtensionConfiguration
    private var capability: BundledLanguageServerCapability?

    public init(specification: BundledLanguagePluginSpecification) {
        manifest = BundledLanguagePluginCatalog.manifests
            .flatMap(\.modules)
            .first { $0.manifest.id == .languageServerExtension(specification.id) }!
            .manifest
        configuration = LanguageServerExtensionConfiguration(
            languageID: specification.id,
            displayName: specification.displayName,
            executableNames: specification.executableNames,
            arguments: specification.arguments,
            validationArguments: specification.validationArguments,
            languageIdentifier: specification.languageIdentifier
        )
    }

    public init(manifest: ModuleManifest, configuration: LanguageServerExtensionConfiguration) {
        self.manifest = manifest
        self.configuration = configuration
    }

    public func activate(context: ModuleContext) async throws {
        let lifecycle = BundledLanguageServerLifecycle()
        context.resources.register(BundledLanguageServerResource(lifecycle: lifecycle))
        capability = BundledLanguageServerCapability(configuration: configuration, lifecycle: lifecycle)
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { releaseCapability() }
    public func shutdown() async { releaseCapability() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.languageServerExtension(configuration.languageID): $0] } ?? [:]
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
        configuration: LanguageServerExtensionConfiguration,
        lifecycle: any LanguageServerExtensionLifecycle
    ) {
        self.configuration = configuration
        self.lifecycle = lifecycle
    }
}

@MainActor
private final class BundledLanguageServerLifecycle: LanguageServerExtensionLifecycle {
    private var running: @MainActor () -> Bool = { false }
    private var stopAction: @MainActor () -> Void = {}

    private(set) var isRetired = false

    var isRunning: Bool { running() }

    func attach(
        isRunning: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        running = isRunning
        stopAction = stop
    }

    func stop() {
        isRetired = true
        stopAction()
    }
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
