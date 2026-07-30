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
    private let maximumOutputCharacters = 240_000

    func start(in workspaceURL: URL) {
        stop()
        self.workspaceURL = workspaceURL
        isReady = false

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
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
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning = false
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            self.outputPipe = outputPipe
            isRunning = true
            Task { [weak self] in
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let self, self.isRunning, !self.isReady else { return }
                    self.writeRaw("\n")
                }
            }
        } catch {
            append("Unable to start terminal: \(error.localizedDescription)\n")
        }
    }

    func restart() {
        guard let workspaceURL else { return }
        start(in: workspaceURL)
    }

    func send(_ command: String) {
        guard isRunning, isReady else { return }
        writeRaw(command + "\n")
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
    }

    private func append(_ chunk: String) {
        isReady = true
        output.append(Self.plainText(from: chunk))
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

    private static func plainText(from value: String) -> String {
        let pattern = "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\))"
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let withoutANSI = (try? NSRegularExpression(pattern: pattern))?
            .stringByReplacingMatches(in: value, range: range, withTemplate: "") ?? value
        let normalized = withoutANSI.replacingOccurrences(of: "\r\n", with: "\n")
        var result = ""
        for scalar in normalized.unicodeScalars {
            switch scalar.value {
            case 8, 127:
                if !result.isEmpty { result.removeLast() }
            case 9, 10:
                result.unicodeScalars.append(scalar)
            case 13:
                continue
            case 0..<32:
                continue
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
