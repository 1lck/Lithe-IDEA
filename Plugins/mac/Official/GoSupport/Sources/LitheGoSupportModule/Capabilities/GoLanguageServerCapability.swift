import Foundation
import LitheCoreContracts
import LitheModuleAPI

@MainActor
public final class GoLanguageServerCapability: NSObject, LanguageServerExtensionProviding {
    public let configuration: LanguageServerExtensionConfiguration
    public let lifecycle: any LanguageServerExtensionLifecycle

    init(lifecycle: any LanguageServerExtensionLifecycle, launch: PluginLanguageServerLaunch = GoSupportManifest.languageServerLaunch) {
        configuration = LanguageServerExtensionConfiguration(
            languageID: GoSupportManifest.languageID,
            displayName: "Go",
            executableNames: [launch.executable],
            arguments: launch.arguments,
            validationArguments: launch.validationArguments,
            languageIdentifier: GoSupportManifest.languageID
        )
        self.lifecycle = lifecycle
    }
}

@MainActor
final class GoLanguageServerLifecycle: LanguageServerExtensionLifecycle {
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

    func stop() {
        stopAction()
    }
}
