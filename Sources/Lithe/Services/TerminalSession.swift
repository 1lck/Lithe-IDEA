import Foundation

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var shellName = "Shell"

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var workspaceURL: URL?
    private var selectedShellPath: String?
    private var terminalBuffer = TerminalBuffer()
    private let maximumOutputCharacters = 240_000

    func start(in workspaceURL: URL, shellPath: String? = nil) {
        stop()
        self.workspaceURL = workspaceURL
        terminalBuffer.reset()
        output = ""

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

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self, weak process] in
                guard let self, let process, self.process === process else { return }
                self.append(chunk)
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
            // The PTY can accept queued input while the shell startup files run.
            // Avoid timing-based handshakes that can leak markers into the prompt.
            isReady = true
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
        sendInput(command + "\n")
    }

    func sendInput(_ input: String) {
        guard isRunning, isReady else { return }
        writeRaw(input)
    }

    func prepareForInput() {
        guard isRunning else { return }
    }

    func interrupt() {
        guard isRunning else { return }
        try? inputPipe?.fileHandleForWriting.write(contentsOf: Data([0x03]))
    }

    func clear() {
        terminalBuffer.reset()
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
        terminalBuffer.append(chunk)
        output = terminalBuffer.render(maxCharacters: maximumOutputCharacters)
    }

    private func appendOutput(_ value: String) {
        append(value)
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

private struct TerminalBuffer {
    private enum EscapeMode {
        case normal
        case escape
        case csi
        case osc
        case oscEscape
    }

    private var lines: [[Character]] = [[]]
    private var row = 0
    private var column = 0
    private var savedRow = 0
    private var savedColumn = 0
    private var escapeMode: EscapeMode = .normal
    private var csiParameters = ""
    private let maximumRows = 2_000

    mutating func reset() {
        lines = [[]]
        row = 0
        column = 0
        savedRow = 0
        savedColumn = 0
        escapeMode = .normal
        csiParameters = ""
    }

    mutating func append(_ value: String) {
        for scalar in value.unicodeScalars {
            consume(scalar)
        }
    }

    func render(maxCharacters: Int) -> String {
        let rendered = lines
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        guard rendered.count > maxCharacters else { return rendered }
        return String(rendered.suffix(maxCharacters))
    }

    private mutating func consume(_ scalar: Unicode.Scalar) {
        switch escapeMode {
        case .escape:
            consumeEscape(scalar)
        case .csi:
            if (64...126).contains(scalar.value) {
                handleCSI(final: scalar)
                escapeMode = .normal
                csiParameters = ""
            } else {
                csiParameters.unicodeScalars.append(scalar)
            }
        case .osc:
            if scalar.value == 7 {
                escapeMode = .normal
            } else if scalar.value == 27 {
                escapeMode = .oscEscape
            }
        case .oscEscape:
            escapeMode = scalar == "\\" ? .normal : .osc
        case .normal:
            consumeText(scalar)
        }
    }

    private mutating func consumeEscape(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "[":
            escapeMode = .csi
            csiParameters = ""
        case "]":
            escapeMode = .osc
        case "7":
            savedRow = row
            savedColumn = column
            escapeMode = .normal
        case "8":
            row = savedRow
            column = savedColumn
            escapeMode = .normal
        case "c":
            reset()
        default:
            escapeMode = .normal
        }
    }

    private mutating func consumeText(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x1B:
            escapeMode = .escape
        case 8, 127:
            column = max(0, column - 1)
        case 9:
            column = ((column / 8) + 1) * 8
        case 10:
            row += 1
            column = 0
            ensureRow()
        case 13:
            column = 0
        case 0..<32:
            break
        default:
            write(Character(String(scalar)))
        }
    }

    private mutating func write(_ character: Character) {
        ensureRow()
        while lines[row].count < column {
            lines[row].append(" ")
        }
        if column == lines[row].count {
            lines[row].append(character)
        } else {
            lines[row][column] = character
        }
        column += 1
        if column >= 240 {
            column = 0
            row += 1
            ensureRow()
        }
    }

    private mutating func ensureRow() {
        while lines.count <= row {
            lines.append([])
        }
        if lines.count > maximumRows {
            let removeCount = lines.count - maximumRows
            lines.removeFirst(removeCount)
            row -= removeCount
            savedRow = max(0, savedRow - removeCount)
        }
    }

    private mutating func handleCSI(final: Unicode.Scalar) {
        let values = csiParameters
            .trimmingCharacters(in: CharacterSet(charactersIn: "? >"))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        let first = values.first.flatMap { $0 == 0 ? nil : $0 } ?? 1

        switch final {
        case "A":
            row = max(0, row - first)
        case "B", "e":
            row += first
            ensureRow()
        case "C", "a":
            column += first
        case "D":
            column = max(0, column - first)
        case "G":
            column = max(0, first - 1)
        case "d":
            row = max(0, first - 1)
            ensureRow()
        case "H", "f":
            row = max(0, (values.first ?? 1) - 1)
            column = max(0, (values.dropFirst().first ?? 1) - 1)
            ensureRow()
        case "J":
            eraseDisplay(mode: values.first ?? 0)
        case "K":
            eraseLine(mode: values.first ?? 0)
        case "s":
            savedRow = row
            savedColumn = column
        case "u":
            row = savedRow
            column = savedColumn
            ensureRow()
        default:
            break
        }
    }

    private mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 2, 3:
            reset()
        case 1:
            for index in 0...min(row, lines.count - 1) {
                lines[index] = []
            }
            row = min(row, lines.count - 1)
            column = 0
        default:
            guard row < lines.count else { return }
            lines[row] = Array(lines[row].prefix(column))
            if row + 1 < lines.count {
                lines.removeSubrange((row + 1)..<lines.count)
            }
        }
    }

    private mutating func eraseLine(mode: Int) {
        ensureRow()
        switch mode {
        case 1:
            lines[row] = Array(lines[row].dropFirst(min(column, lines[row].count)))
            column = 0
        case 2:
            lines[row] = []
            column = 0
        default:
            if column < lines[row].count {
                lines[row].removeSubrange(column..<lines[row].count)
            }
        }
    }
}
