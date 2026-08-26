import LitheCoreContracts
import LitheModuleAPI

@MainActor
final class MacLanguageExecutionHost: LanguageExecutionHostProviding {
    private let processRegistry: ManagedProcessRegistry

    init(processRegistry: ManagedProcessRegistry) {
        self.processRegistry = processRegistry
    }

    func makeSession(ownerModuleID: ModuleID) -> any LanguageExecutionSession {
        MacLanguageExecutionSession(process: MacStreamingProcess(
            processRegistry: processRegistry,
            moduleID: ownerModuleID
        ))
    }
}

@MainActor
private final class MacLanguageExecutionSession: LanguageExecutionSession {
    var isRunning: Bool { process.isRunning }

    var onOutput: (@Sendable (String) -> Void)? {
        didSet { process.onOutput = onOutput }
    }
    var onTermination: (@Sendable (Int32) -> Void)? {
        didSet { process.onTermination = onTermination }
    }
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)? {
        didSet { installStateForwarding() }
    }

    private let process: MacStreamingProcess

    init(process: MacStreamingProcess) {
        self.process = process
    }

    func start(_ request: LanguageExecutionProcessRequest) throws {
        try process.start(ProcessRequest(
            operationID: request.operationID,
            executablePath: request.executablePath,
            arguments: request.arguments,
            workingDirectory: request.workingDirectory,
            environment: request.environment
        ))
    }

    func stop() {
        process.stop()
    }

    func stopAndWait() async -> Bool {
        await process.stopAndWait()
    }

    private func installStateForwarding() {
        let callback = onStateChange
        process.onStateChange = { event in
            callback?(LanguageExecutionLifecycleEvent(
                operationID: event.operationID,
                state: Self.state(event.state),
                exitCode: event.exitCode,
                message: event.message
            ))
        }
    }

    private nonisolated static func state(
        _ state: ProcessLifecycleState
    ) -> LanguageExecutionLifecycleState {
        switch state {
        case .starting: .starting
        case .running: .running
        case .stopping: .stopping
        case .finished: .finished
        case .failed: .failed
        }
    }
}
