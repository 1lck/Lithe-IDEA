import Foundation

/// Adapts the existing managed process to a bounded, cancellable installation
/// command. Cancellation waits for the process group before releasing resources.
@MainActor
final class MacPluginToolchainProcessOperation {
    private let process: MacStreamingProcess
    private let output = OutputBuffer()
    private var completion: CheckedContinuation<ProcessResult, Error>?

    init(processRegistry: ManagedProcessRegistry? = nil) {
        process = MacStreamingProcess(processRegistry: processRegistry)
    }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        output.reset()
        defer {
            process.onOutput = nil
            process.onTermination = nil
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                process.onOutput = { [output] in output.append($0) }
                process.onTermination = { [weak self] status in
                    Task { @MainActor in
                        guard let self else { return }
                        self.finish(.success(ProcessResult(output: self.output.value, exitCode: status)))
                    }
                }
                do { try process.start(request) }
                catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in
                let stopped = await self.process.stopAndWait()
                self.finish(.failure(stopped ? CancellationError() : PluginToolchainError.validationFailed("The tool process could not be stopped.")))
            }
        }
    }

    private func finish(_ result: Result<ProcessResult, Error>) {
        let continuation = completion
        completion = nil
        continuation?.resume(with: result)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    var value: String { lock.withLock { text } }
    func reset() { lock.withLock { text = "" } }
    func append(_ value: String) {
        // Upstream installers may emit large logs. Keep only a bounded tail.
        lock.withLock { text = String((text + value).suffix(16_384)) }
    }
}
