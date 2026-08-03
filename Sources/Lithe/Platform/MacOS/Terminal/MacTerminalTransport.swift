import Foundation

final class MacTerminalTransport: TerminalTransport, @unchecked Sendable {
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable () -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?

    func defaultShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    func defaultEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    func start(
        workingDirectory: String,
        shellPath: String,
        environment: [String: String]
    ) throws {
        stop()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", shellPath, "-l"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = environment

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
            self.onTermination?()
        }

        try process.run()
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
    }

    func send(_ input: Data) throws {
        try inputPipe?.fileHandleForWriting.write(contentsOf: input)
    }

    func interrupt() throws {
        try send(Data([0x03]))
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
    }
}
