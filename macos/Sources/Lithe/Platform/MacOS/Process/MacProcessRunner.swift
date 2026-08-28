import Darwin
import Foundation
import LitheCoreContracts

final class MacProcessRunner: ProcessRunner, @unchecked Sendable {
    private static let pollingInterval: TimeInterval = 0.01
    private static let outputDrainGracePeriod: TimeInterval = 0.2
    private static let terminationGracePeriod: TimeInterval = 0.2
    private static let forcedTerminationGracePeriod: TimeInterval = 1

    func run(_ request: ProcessRequest) -> ProcessResult {
        let outputPipe = Pipe()
        let inputPipe = request.standardInput.map { _ in Pipe() }
        let process = MacManagedProcess(
            executableURL: URL(fileURLWithPath: request.executablePath),
            arguments: request.arguments,
            currentDirectoryURL: request.workingDirectory.map(URL.init(fileURLWithPath:)),
            environment: request.environment,
            standardInput: inputPipe?.fileHandleForReading ?? FileHandle.nullDevice,
            standardOutput: outputPipe.fileHandleForWriting,
            standardError: outputPipe.fileHandleForWriting
        )
        let outputLock = NSLock()
        var output = Data()
        var reachedOutputEOF = false
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            outputLock.lock()
            if data.isEmpty {
                reachedOutputEOF = true
            } else {
                output.append(data)
            }
            outputLock.unlock()
        }
        if let inputPipe {
            // A timed-out child can close stdin while a write is in flight.
            // Convert SIGPIPE into a write error instead of terminating Lithe.
            _ = Darwin.fcntl(
                inputPipe.fileHandleForWriting.fileDescriptor,
                F_SETNOSIGPIPE,
                1
            )
        }

        do {
            try process.run()
            try? inputPipe?.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            if let input = request.standardInput, let inputPipe {
                // Large input must not prevent this thread from enforcing the
                // process deadline when a child stops reading stdin.
                DispatchQueue.global(qos: .utility).async {
                    try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inputPipe.fileHandleForWriting.close()
                }
            }
            let deadline = request.timeoutMilliseconds.map {
                Date().addingTimeInterval(TimeInterval($0) / 1000)
            }
            var timedOut = false
            while process.isRunning {
                if let deadline, Date() >= deadline {
                    timedOut = true
                    process.terminateAndWait(
                        gracePeriod: Self.terminationGracePeriod,
                        forcedTerminationTimeout: Self.forcedTerminationGracePeriod
                    )
                    break
                }
                Thread.sleep(forTimeInterval: Self.pollingInterval)
            }
            try? inputPipe?.fileHandleForWriting.close()
            if !process.isRunning {
                // The managed process group removes inherited-pipe descendants;
                // the grace period only lets the final readability event arrive.
                let drainDeadline = Date().addingTimeInterval(Self.outputDrainGracePeriod)
                while Date() < drainDeadline {
                    outputLock.lock()
                    let didReachOutputEOF = reachedOutputEOF
                    outputLock.unlock()
                    if didReachOutputEOF { break }
                    Thread.sleep(forTimeInterval: Self.pollingInterval)
                }
            }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            let data = outputLock.withLock { output }
            return ProcessResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: timedOut ? 124 : process.terminationStatus
            )
        } catch {
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
            return ProcessResult(output: error.localizedDescription, exitCode: 1)
        }
    }
}

extension MacProcessRunner: LanguageToolCommandRunning {
    func runLanguageToolCommand(
        operationID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeoutMilliseconds: Int
    ) -> LanguageToolCommandResult {
        let result = run(ProcessRequest(
            operationID: operationID,
            executablePath: executableURL.path,
            arguments: arguments,
            environment: environment,
            timeoutMilliseconds: timeoutMilliseconds
        ))
        return LanguageToolCommandResult(output: result.output, exitCode: result.exitCode)
    }
}
