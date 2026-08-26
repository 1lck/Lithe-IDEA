import Foundation
import LitheCoreContracts

/// Adapts a macOS child process to the platform-neutral DAP transport contract.
@MainActor
final class MacProcessDebugAdapterTransport: DebugAdapterTransport {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]
    private let process: any RawProcessSession

    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        process: any RawProcessSession
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.process = process
        process.onOutput = { [weak self] data in
            Task { @MainActor [weak self] in self?.onData?(data) }
        }
        process.onError = { [weak self] data in
            Task { @MainActor [weak self] in self?.onErrorOutput?(data) }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in self?.onTermination?(Int(exitCode)) }
        }
    }

    var isRunning: Bool { process.isRunning }

    func start(rootURL: URL) throws {
        try process.start(ProcessRequest(
            operationID: UUID().uuidString,
            executablePath: executableURL.path,
            arguments: arguments,
            workingDirectory: rootURL.standardizedFileURL.path,
            environment: environment,
            keepsStandardInputOpen: true
        ))
    }

    func send(_ data: Data) throws {
        try process.send(data)
    }

    func stop() {
        process.stop()
    }
}
