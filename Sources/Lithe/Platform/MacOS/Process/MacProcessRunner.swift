import Foundation
import LitheCoreContracts

final class MacProcessRunner: ProcessRunner, @unchecked Sendable {
    func run(_ request: ProcessRequest) -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = request.standardInput.map { _ in Pipe() }
        let outputLock = NSLock()
        var output = Data()
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputLock.lock()
            output.append(data)
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

        do {
            try process.run()
            if let input = request.standardInput, let inputPipe {
                try inputPipe.fileHandleForWriting.write(contentsOf: input)
                try inputPipe.fileHandleForWriting.close()
            }
            let deadline = request.timeoutMilliseconds.map {
                Date().addingTimeInterval(TimeInterval($0) / 1000)
            }
            var timedOut = false
            while process.isRunning {
                if let deadline, Date() >= deadline {
                    timedOut = true
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let remaining = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            output.append(remaining)
            let data = output
            outputLock.unlock()
            return ProcessResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: timedOut ? 124 : process.terminationStatus
            )
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
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
