import Darwin
import Foundation
import LitheCoreContracts

final class MacProcessRunner: ProcessRunner, @unchecked Sendable {
    private static let pollingInterval: TimeInterval = 0.01
    private static let outputDrainGracePeriod: TimeInterval = 0.2
    private static let terminationGracePeriod: TimeInterval = 0.2
    private static let forcedTerminationGracePeriod: TimeInterval = 1

    func run(_ request: ProcessRequest) -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = request.standardInput.map { _ in Pipe() }
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

        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if let environment = request.environment {
            process.environment = environment
        }
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe ?? FileHandle.nullDevice
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
                    terminateAndWait(process)
                    break
                }
                Thread.sleep(forTimeInterval: Self.pollingInterval)
            }
            try? inputPipe?.fileHandleForWriting.close()
            if !process.isRunning {
                // Descendants can inherit the pipe, so EOF is only given a
                // bounded grace period rather than becoming another wait.
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
            outputLock.lock()
            let data = output
            outputLock.unlock()
            return ProcessResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: timedOut ? 124 : process.terminationStatus
            )
        } catch {
            try? inputPipe?.fileHandleForWriting.close()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return ProcessResult(output: error.localizedDescription, exitCode: 1)
        }
    }

    private func terminateAndWait(_ process: Process) {
        MacProcessTree(rootPID: process.processIdentifier).terminateAndWait(
            gracePeriod: Self.terminationGracePeriod,
            forcedTerminationTimeout: Self.forcedTerminationGracePeriod
        )
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
