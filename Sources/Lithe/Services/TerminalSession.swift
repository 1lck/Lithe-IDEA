import Foundation

@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var shellName = "Shell"

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var workspaceURL: URL?
    private var selectedShellPath: String?
    private var startupBuffer = ""
    private var didCompleteHandshake = false
    private let maximumOutputCharacters = 240_000
    private let handshakeMarker = "__LITHE_READY__"

    func start(in workspaceURL: URL, shellPath: String? = nil) {
        stop()
        self.workspaceURL = workspaceURL
        isReady = false
        startupBuffer = ""
        didCompleteHandshake = false

        let shell = shellPath ?? selectedShellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        selectedShellPath = shell
        shellName = URL(fileURLWithPath: shell).lastPathComponent

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", shell, "-l"]
        process.currentDirectoryURL = workspaceURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.append(chunk)
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                guard self?.process === terminatedProcess else { return }
                self?.isRunning = false
                self?.isReady = false
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            isRunning = true
            Task { [weak self, weak process] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, let process, self.process === process, process.isRunning else { return }
                self.writeRaw("printf '__LITHE_%s__\\n' READY\n")
                try? await Task.sleep(for: .milliseconds(1_300))
                guard self.process === process, process.isRunning, !self.didCompleteHandshake else { return }
                self.startupBuffer = ""
                self.didCompleteHandshake = true
                self.isReady = true
                self.writeRaw("\n")
            }
        } catch {
            append("Unable to start terminal: \(error.localizedDescription)\n")
        }
    }

    func restart() {
        guard let workspaceURL else { return }
        start(in: workspaceURL, shellPath: selectedShellPath)
    }

    func restart(using shellPath: String) {
        guard let workspaceURL else { return }
        start(in: workspaceURL, shellPath: shellPath)
    }

    func send(_ command: String) {
        guard isRunning, isReady else { return }
        writeRaw(command + "\n")
    }

    func prepareForInput() {
        guard isRunning else { return }
    }

    func interrupt() {
        guard isRunning else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data([0x03]))
    }

    func clear() {
        output = ""
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
        isRunning = false
        isReady = false
        startupBuffer = ""
        didCompleteHandshake = false
    }

    private func append(_ chunk: String) {
        guard !didCompleteHandshake else {
            appendOutput(chunk)
            return
        }

        startupBuffer.append(chunk)
        guard let markerRange = startupBuffer.range(of: handshakeMarker) else { return }
        let content = String(startupBuffer[markerRange.upperBound...])
        startupBuffer = ""
        didCompleteHandshake = true
        isReady = true
        appendOutput(content)
    }

    private func appendOutput(_ value: String) {
        output.append(value)
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func writeRaw(_ value: String) {
        guard isRunning, let data = value.data(using: .utf8) else { return }
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: data)
        } catch {
            append("Unable to write to terminal: \(error.localizedDescription)\n")
        }
    }

}
