import Foundation
import LitheCoreContracts

@MainActor
public final class GoLanguageServerCapability: NSObject, LanguageServerExtensionProviding {
    public let configuration = LanguageServerExtensionConfiguration(
        languageID: goLanguageID,
        displayName: "Go",
        executableNames: ["gopls"],
        validationArguments: ["version"],
        languageIdentifier: "go"
    )
    public let lifecycle: any LanguageServerExtensionLifecycle

    init(lifecycle: any LanguageServerExtensionLifecycle) {
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
