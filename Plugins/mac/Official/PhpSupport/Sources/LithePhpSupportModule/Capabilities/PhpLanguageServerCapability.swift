import Foundation
import LitheCoreContracts

@MainActor
public final class PhpLanguageServerCapability: NSObject, LanguageServerExtensionProviding {
    public let configuration = LanguageServerExtensionConfiguration(
        languageID: phpLanguageID,
        displayName: "PHP",
        executableNames: ["intelephense"],
        arguments: ["--stdio"],
        // Intelephense advertises neither `--version` nor `--help`: both exit
        // non-zero and dump its bundled source to stderr, and validation only
        // accepts a zero exit code. Declaring one would reject every candidate
        // and surface as "intelephense was not found". Absent validation
        // arguments, the host treats a discovered candidate as usable and lets
        // the stdio handshake decide.
        validationArguments: [],
        languageIdentifier: "php"
    )
    public let lifecycle: any LanguageServerExtensionLifecycle

    init(lifecycle: any LanguageServerExtensionLifecycle) {
        self.lifecycle = lifecycle
    }
}

@MainActor
final class PhpLanguageServerLifecycle: LanguageServerExtensionLifecycle {
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
