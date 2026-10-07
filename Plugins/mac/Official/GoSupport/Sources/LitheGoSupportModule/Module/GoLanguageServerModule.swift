import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class GoLanguageServerModule: LitheModule {
    public static let moduleManifest = GoSupportManifest.languageServerModule

    public let manifest = moduleManifest
    private var capability: GoLanguageServerCapability?

    private let launch: PluginLanguageServerLaunch
    public init(launch: PluginLanguageServerLaunch = GoSupportManifest.languageServerLaunch) { self.launch = launch }

    public func activate(context: ModuleContext) async throws {
        let lifecycle = GoLanguageServerLifecycle()
        context.resources.register(GoLanguageServerResource(lifecycle: lifecycle))
        capability = GoLanguageServerCapability(lifecycle: lifecycle, launch: launch)
    }

    public func prepareForSleep() async throws {}
    public func sleep() async { releaseCapability() }
    public func shutdown() async { releaseCapability() }

    public func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] {
        capability.map { [.languageServerExtension(goLanguageID): $0] } ?? [:]
    }

    private func releaseCapability() {
        capability?.lifecycle.stop()
        capability = nil
    }
}

@MainActor
private final class GoLanguageServerResource: ModuleResource {
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
