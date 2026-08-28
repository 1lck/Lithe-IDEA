import Darwin
import Foundation
import LitheModuleAPI

final class MacStreamingProcess: StreamingProcess, @unchecked Sendable {
    private static let forcedTerminationDelay: Duration = .milliseconds(200)

    var isRunning: Bool { process?.isRunning == true }
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)?

    private var process: MacManagedProcess?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var timeoutTask: Task<Void, Never>?
    private var activeOperationID: String?
    private let processRegistry: ManagedProcessRegistry?
    private let category: ManagedProcessCategory
    private let moduleID: ModuleID?
    private var registeredPID: Int32?

    init(
        processRegistry: ManagedProcessRegistry? = nil,
        category: ManagedProcessCategory = .service,
        moduleID: ModuleID? = nil
    ) {
        self.processRegistry = processRegistry
        self.category = category
        self.moduleID = moduleID
    }

    func start(_ request: ProcessRequest) throws {
        stop()
        activeOperationID = request.operationID
        onStateChange?(ProcessLifecycleEvent(
            operationID: request.operationID,
            state: .starting,
            exitCode: nil,
            message: nil
        ))

        let outputPipe = Pipe()
        let inputPipe = (request.standardInput != nil || request.keepsStandardInputOpen)
            ? Pipe()
            : nil
        let process = MacManagedProcess(
            executableURL: URL(fileURLWithPath: request.executablePath),
            arguments: request.arguments,
            currentDirectoryURL: request.workingDirectory.map(URL.init(fileURLWithPath:)),
            environment: request.environment,
            standardInput: inputPipe?.fileHandleForReading ?? FileHandle.nullDevice,
            standardOutput: outputPipe.fileHandleForWriting,
            standardError: outputPipe.fileHandleForWriting
        )
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
            self.onOutput?(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self, self.process === terminatedProcess else { return }
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.inputPipe = nil
            self.outputPipe = nil
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.activeOperationID = nil
            self.unregisterProcess()
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
        do {
            try process.run { [self] processIdentifier in
                registeredPID = processIdentifier
                processRegistry?.register(
                    pid: processIdentifier,
                    category: category,
                    moduleID: moduleID
                )
            }
            try? inputPipe?.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        } catch {
            closePipes()
            self.process = nil
            onStateChange?(ProcessLifecycleEvent(
                operationID: request.operationID,
                state: .failed,
                exitCode: nil,
                message: error.localizedDescription
            ))
            activeOperationID = nil
            throw error
        }
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
        try inputPipe?.fileHandleForWriting.write(contentsOf: input)
    }

    func stop() {
        _ = stopProcessGroup()
    }

    func stopAndWait() async -> Bool {
        guard let terminationTask = stopProcessGroup() else { return true }
        return await terminationTask.value
    }

    private func stopProcessGroup() -> Task<Bool, Never>? {
        timeoutTask?.cancel()
        timeoutTask = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        var terminationTask: Task<Bool, Never>?
        if let process, process.isRunning {
            onStateChange?(ProcessLifecycleEvent(
                operationID: activeOperationID,
                state: .stopping,
                exitCode: nil,
                message: "Process stopped"
            ))
            terminationTask = process.terminate()
        }
        closePipes()
        unregisterProcess()
        process = nil
        activeOperationID = nil
        return terminationTask
    }

    private func closePipes() {
        try? inputPipe?.fileHandleForReading.close()
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? outputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        outputPipe = nil
    }

    private func unregisterProcess() {
        guard let registeredPID else { return }
        processRegistry?.unregister(pid: registeredPID, category: category, moduleID: moduleID)
        self.registeredPID = nil
    }

    private func scheduleTimeout(
        _ milliseconds: Int?,
        for process: MacManagedProcess,
        operationID: String?
    ) {
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
            _ = process.terminate(gracePeriod: Self.forcedTerminationDelay)
        }
    }
}
