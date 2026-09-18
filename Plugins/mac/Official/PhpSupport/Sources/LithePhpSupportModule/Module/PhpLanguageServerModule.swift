import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class PhpLanguageServerModule: LitheModule {
    public static let moduleManifest = OfficialPluginCatalog.moduleManifest(
        for: .languageServerExtension(phpLanguageID)
    )!

    public let manifest = moduleManifest
    private var capability: PhpLanguageServerCapability?

    public init() {}

    public func activate(context: ModuleContext) async throws {
        let lifecycle = PhpLanguageServerLifecycle()
        context.resources.register(PhpLanguageServerResource(lifecycle: lifecycle))
        capability = PhpLanguageServerCapability(lifecycle: lifecycle)
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { releaseCapability() }
    public func shutdown() async { releaseCapability() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.languageServerExtension(phpLanguageID): $0] } ?? [:]
    }

    private func releaseCapability() {
        capability?.lifecycle.stop()
        capability = nil
    }
}

@MainActor
private final class PhpLanguageServerResource: ModuleResource {
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
