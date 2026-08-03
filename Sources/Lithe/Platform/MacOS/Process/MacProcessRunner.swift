import Foundation

final class MacProcessRunner: ProcessRunner, @unchecked Sendable {
    func run(_ request: ProcessRequest) -> ProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = request.standardInput.map { _ in Pipe() }

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
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(
                output: String(data: data, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )
        } catch {
            return ProcessResult(output: error.localizedDescription, exitCode: 1)
        }
    }
}

final class MacGitCommandRunner: GitCommandRunner, @unchecked Sendable {
    private let processRunner: any ProcessRunner

    init(processRunner: any ProcessRunner = MacProcessRunner()) {
        self.processRunner = processRunner
    }

    func run(
        arguments: [String],
        workingDirectory: String,
        input: String?
    ) -> ProcessResult {
        processRunner.run(ProcessRequest(
            executablePath: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: workingDirectory,
            standardInput: input.map { Data($0.utf8) }
        ))
    }
}
