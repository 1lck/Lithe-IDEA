import LitheModuleAPI
import Darwin
import Foundation
import LitheCoreContracts

final class MacProcessRunner: ProcessRunner, @unchecked Sendable {
    private static let pollingInterval: TimeInterval = 0.01
    private static let outputDrainGracePeriod: TimeInterval = 0.2
    private static let terminationGracePeriod: TimeInterval = 0.2
    private static let forcedTerminationGracePeriod: TimeInterval = 1

    private let logging: (any LogSink)?
    init(logging: (any LogSink)? = nil) { self.logging = logging }

    func run(_ request: ProcessRequest) -> ProcessResult {
        if Task<Never, Never>.isCancelled {
            return ProcessResult(output: "Process cancelled", exitCode: 130)
        }
        let operation = request.operationID ?? UUID().uuidString
        var span = RunProcessExecutionSpan.begin(executable: URL(fileURLWithPath: request.executablePath), operationID: operation, emit: { [logging] in logging?.emit($0) })

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
            do { try inputPipe?.fileHandleForReading.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
            do { try outputPipe.fileHandleForWriting.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
            if let input = request.standardInput, let inputPipe {
                // Large input must not prevent this thread from enforcing the
                // process deadline when a child stops reading stdin.
                DispatchQueue.global(qos: .utility).async { [logging] in
                    do { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
                    catch { logging?.emit(RunProcessIoFailed(error: error, stage: "stdin-write", operationID: operation)) }
                    do { try inputPipe.fileHandleForWriting.close() }
                    catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
                }
            }
            let deadline = request.timeoutMilliseconds.map {
                Date().addingTimeInterval(TimeInterval($0) / 1000)
            }
            var timedOut = false
            var cancelled = false
            while process.isRunning {
                if Task<Never, Never>.isCancelled {
                    cancelled = true
                    process.terminateAndWait(
                        gracePeriod: Self.terminationGracePeriod,
                        forcedTerminationTimeout: Self.forcedTerminationGracePeriod
                    )
                    break
                }
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
            do { try inputPipe?.fileHandleForWriting.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
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
            do { try outputPipe.fileHandleForReading.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
            let data = outputLock.withLock { output }
            let code = Int64(timedOut ? 124 : cancelled ? 130 : process.terminationStatus)
            let outcome = timedOut ? "timed_out" : cancelled ? "cancelled" : "exited"
            if code == 0 { span.finish(exitCode: code, outcome: outcome) }
            else { span.fail(NSError(domain: "process", code: Int(code)), exitCode: code, outcome: outcome) }
            return ProcessResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: timedOut ? 124 : cancelled ? 130 : process.terminationStatus
            )
        } catch {
            do { try inputPipe?.fileHandleForReading.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
            do { try inputPipe?.fileHandleForWriting.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
            do { try outputPipe.fileHandleForWriting.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
            outputPipe.fileHandleForReading.readabilityHandler = nil
            do { try outputPipe.fileHandleForReading.close() }
            catch { logging?.emit(RunProcessIoFailed(error: error, stage: "close", operationID: operation)) }
            span.fail(error, outcome: "launch_failed")
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
