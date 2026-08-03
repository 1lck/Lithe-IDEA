import Foundation

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var output = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var shellName = "Shell"

    private let transport: any TerminalTransport
    private var workspaceURL: URL?
    private var selectedShellPath: String?
    private var terminalBuffer = TerminalBuffer()
    private let maximumOutputCharacters = 240_000

    init(transport: any TerminalTransport) {
        self.transport = transport
        transport.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                self?.append(chunk)
            }
        }
        transport.onTermination = { [weak self] in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.isReady = false
            }
        }
    }

    func start(in workspaceURL: URL, shellPath: String? = nil) {
        stop()
        self.workspaceURL = workspaceURL
        terminalBuffer.reset()
        output = ""

        let shell = shellPath ?? selectedShellPath ?? transport.defaultShellPath()
        selectedShellPath = shell
        shellName = URL(fileURLWithPath: shell).lastPathComponent

        var environment = transport.defaultEnvironment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"

        do {
            try transport.start(
                workingDirectory: workspaceURL.path,
                shellPath: shell,
                environment: environment
            )
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

    func interrupt() {
        guard isRunning else { return }
        try? transport.interrupt()
    }

    func clear() {
        terminalBuffer.reset()
        output = ""
    }

    func stop() {
        transport.stop()
        isRunning = false
        isReady = false
    }

    private func append(_ chunk: String) {
        terminalBuffer.append(chunk)
        output = terminalBuffer.render(maxCharacters: maximumOutputCharacters)
    }

    private func writeRaw(_ value: String) {
        guard isRunning, let data = value.data(using: .utf8) else { return }
        do {
            try transport.send(data)
        } catch {
            append("Unable to write to terminal: \(error.localizedDescription)\n")
        }
    }

}
