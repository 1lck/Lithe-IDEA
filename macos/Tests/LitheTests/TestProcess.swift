import Darwin
import Foundation
@testable import Lithe

struct TestProcessResult: Sendable {
    let terminationStatus: Int32
    let output: Data
}

enum TestProcessError: Error {
    case timedOut(executable: String, arguments: [String])
    case cancelled(executable: String, arguments: [String])
}

enum TestProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeout: Duration = .seconds(5)
    ) async throws -> TestProcessResult {
        try Task.checkCancellation()
        let controller = TestProcessController(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            timeout: timeout
        )
        return try await withTaskCancellationHandler {
            try await controller.run()
        } onCancel: {
            controller.cancel()
        }
    }
}

private final class TestProcessController: @unchecked Sendable {
    private let process: MacManagedProcess
    private let output = Pipe()
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: Duration
    private let lock = NSLock()
    private let outputEOF = DispatchSemaphore(value: 0)
    private var continuation: CheckedContinuation<TestProcessResult, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var terminalError: (any Error)?
    private var capturedOutput = Data()
    private var reachedOutputEOF = false
    private var didFinish = false

    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeout: Duration
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
        process = MacManagedProcess(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            standardInput: FileHandle.nullDevice,
            standardOutput: output.fileHandleForWriting,
            standardError: output.fileHandleForWriting
        )
    }

    func run() async throws -> TestProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            var launchError: (any Error)?
            var pendingError: (any Error)?
            lock.lock()
            self.continuation = continuation
            pendingError = terminalError
            if pendingError == nil {
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    self?.recordOutput(data)
                }
                process.terminationHandler = { [weak self] terminatedProcess in
                    self?.processDidTerminate(status: terminatedProcess.terminationStatus)
                }
                do {
                    try process.run()
                    try? output.fileHandleForWriting.close()
                } catch {
                    launchError = error
                }
            }
            if pendingError == nil, launchError == nil {
                timeoutTask = Task { [weak self, timeout] in
                    // test-stability: allow(swift-real-sleep) reason: this watchdog is the bounded deadline for a native subprocess with no injectable clock.
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.stop(
                        with: TestProcessError.timedOut(
                            executable: self?.executableURL.path ?? "",
                            arguments: self?.arguments ?? []
                        )
                    )
                }
            }
            lock.unlock()
            if let pendingError {
                finish(.failure(pendingError))
            } else if let launchError {
                finish(.failure(launchError))
            }
        }
    }

    func cancel() {
        stop(
            with: TestProcessError.cancelled(
                executable: executableURL.path,
                arguments: arguments
            )
        )
    }

    private func stop(with error: any Error) {
        let shouldStop = lock.withLock { () -> Bool in
            guard !didFinish else { return false }
            terminalError = terminalError ?? error
            return true
        }
        guard shouldStop else { return }
        if process.isRunning {
            process.terminate()
        } else {
            finish(.failure(error))
        }
    }

    private func processDidTerminate(status: Int32) {
        _ = outputEOF.wait(timeout: .now() + 0.2)
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        let state = lock.withLock { (terminalError, capturedOutput) }
        let result = state.0.map(Result.failure)
            ?? .success(TestProcessResult(terminationStatus: status, output: state.1))
        finish(result)
    }

    private func recordOutput(_ data: Data) {
        let reachedEOF = lock.withLock { () -> Bool in
            if data.isEmpty {
                guard !reachedOutputEOF else { return false }
                reachedOutputEOF = true
                return true
            } else {
                capturedOutput.append(data)
                return false
            }
        }
        if reachedEOF {
            outputEOF.signal()
        }
    }

    private func finish(_ result: Result<TestProcessResult, any Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<TestProcessResult, any Error>, Task<Void, Never>?)? in
            guard !didFinish, let continuation else { return nil }
            didFinish = true
            self.continuation = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            return (continuation, timeoutTask)
        }
        guard let state else { return }
        state.1?.cancel()
        state.0.resume(with: result)
    }
}
