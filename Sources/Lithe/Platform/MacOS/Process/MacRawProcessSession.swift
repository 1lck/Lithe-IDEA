import Foundation

final class MacRawProcessSession: RawProcessSession, @unchecked Sendable {
    var isRunning: Bool { process?.isRunning == true }
    var onOutput: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    func start(_ request: ProcessRequest) throws {
        stop()

        let process = Process()
        let inputPipe = (request.standardInput != nil || request.keepsStandardInputOpen)
            ? Pipe()
            : nil
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        if let environment = request.environment {
            process.environment = environment
        }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self, let process, self.process === process else { return }
            self.onOutput?(data)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self, let process, self.process === process else { return }
            self.onError?(data)
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self, self.process === terminatedProcess else { return }
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.errorPipe?.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.inputPipe = nil
            self.outputPipe = nil
            self.errorPipe = nil
            self.onTermination?(terminatedProcess.terminationStatus)
        }

        try process.run()
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        if let input = request.standardInput, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            if !request.keepsStandardInputOpen {
                try inputPipe.fileHandleForWriting.close()
            }
        }
    }

    func send(_ input: Data) throws {
        try inputPipe?.fileHandleForWriting.write(contentsOf: input)
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }
}
