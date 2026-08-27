import Darwin
import Foundation

final class MacRawProcessSession: RawProcessSession, @unchecked Sendable {
    private static let forcedTerminationDelay: Duration = .milliseconds(200)

    var isRunning: Bool { process?.isRunning == true }
    var onOutput: (@Sendable (Data) -> Void)?
    var onError: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?

    private var process: Process?
    private var processTree: MacProcessTree?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var timeoutTask: Task<Void, Never>?
    private var activeOperationID: String?

    func start(_ request: ProcessRequest) throws {
        stop()
        activeOperationID = request.operationID
        onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .starting,
            exitCode: nil,
            message: nil
        ))

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
        if let inputPipe {
            // A timed-out child can close stdin while a write is in flight.
            // Convert SIGPIPE into a write error instead of terminating Lithe.
            _ = Darwin.fcntl(
                inputPipe.fileHandleForWriting.fileDescriptor,
                F_SETNOSIGPIPE,
                1
            )
        }

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
            self.processTree = nil
            self.inputPipe = nil
            self.outputPipe = nil
            self.errorPipe = nil
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.activeOperationID = nil
            self.onStateChange?(ProcessLifecycleEvent(
                operationID: request.operationID,
                state: .finished,
                exitCode: terminatedProcess.terminationStatus,
                message: nil
            ))
            self.onTermination?(terminatedProcess.terminationStatus)
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.processTree = nil
            self.inputPipe = nil
            self.outputPipe = nil
            self.errorPipe = nil
            onStateChange?(ProcessLifecycleEvent(
                operationID: request.operationID,
                state: .failed,
                exitCode: nil,
                message: error.localizedDescription
            ))
            activeOperationID = nil
            throw error
        }
        processTree = MacProcessTree(rootPID: process.processIdentifier)
        scheduleTimeout(request.timeoutMilliseconds, for: process, operationID: request.operationID)
        if let input = request.standardInput, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            if !request.keepsStandardInputOpen {
                try inputPipe.fileHandleForWriting.close()
            }
        }
        onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .running,
            exitCode: nil,
            message: nil
        ))
    }

    func send(_ input: Data) throws {
        guard process?.isRunning == true else {
            throw RawProcessSessionError.notRunning
        }
        guard let inputPipe else {
            throw RawProcessSessionError.standardInputUnavailable
        }
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
    }

    func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            onStateChange?(ProcessLifecycleEvent(
                operationID: activeOperationID,
                state: .stopping,
                exitCode: nil,
                message: "Process stopped"
            ))
            (processTree ?? MacProcessTree(rootPID: process.processIdentifier)).terminate()
        }
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        process = nil
        processTree = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        activeOperationID = nil
    }

    private func scheduleTimeout(_ milliseconds: Int?, for process: Process, operationID: String?) {
        guard let milliseconds, milliseconds > 0 else { return }
        timeoutTask = Task { [weak self, weak process] in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled,
                  let self,
                  let process,
                  self.process === process,
                  process.isRunning else { return }
            self.onStateChange?(ProcessLifecycleEvent(
                operationID: operationID,
                state: .stopping,
                exitCode: nil,
                message: "Process timed out"
            ))
            let processTree = self.processTree ?? MacProcessTree(rootPID: process.processIdentifier)
            _ = processTree.terminate(gracePeriod: Self.forcedTerminationDelay)
        }
    }

}
