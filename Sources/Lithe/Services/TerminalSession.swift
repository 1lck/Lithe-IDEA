import Foundation

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()

    @Published private(set) var isRunning = false
    @Published private(set) var isReady = false
    @Published private(set) var shellName = "Shell"
    @Published private(set) var processTitle: String?
    @Published private(set) var currentDirectory: URL?
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?

    /// Receives links recognized by the terminal surface. AppModel supplies the
    /// editor-aware handler when the session is created.
    var onLink: ((String, [String: String]) -> Void)?

    private let transport: any TerminalTransport
    private var workspaceURL: URL?
    private var selectedShellPath: String?
    init(transport: any TerminalTransport) {
        self.transport = transport
        transport.onTermination = { [weak self] exitCode in
            guard let self else { return }
            isRunning = false
            isReady = false
            lastExitCode = exitCode
            endedAt = Date()
        }
        transport.onTitle = { [weak self] title in
            let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.processTitle = normalized.isEmpty ? nil : normalized
        }
        transport.onDirectoryUpdate = { [weak self] directory in
            self?.updateCurrentDirectory(directory)
        }
        transport.onLink = { [weak self] link, params in
            self?.onLink?(link, params)
        }
    }

    var nativeView: AnyObject { transport.nativeView }

    var displayTitle: String {
        if let processTitle, !processTitle.isEmpty {
            return processTitle
        }
        return shellName
    }

    var displayDirectory: String? {
        currentDirectory?.lastPathComponent.nonEmpty
    }

    func elapsedDescription(at date: Date = Date()) -> String? {
        guard let startedAt else { return nil }
        let end = endedAt ?? date
        let elapsed = max(0, end.timeIntervalSince(startedAt))
        let totalSeconds = Int(elapsed.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func start(in workspaceURL: URL, shellPath: String? = nil) {
        stop()
        self.workspaceURL = workspaceURL
        currentDirectory = workspaceURL.standardizedFileURL
        processTitle = nil
        lastExitCode = nil
        startedAt = Date()
        endedAt = nil

        let shell = shellPath ?? selectedShellPath ?? transport.defaultShellPath()
        selectedShellPath = shell
        shellName = URL(fileURLWithPath: shell).lastPathComponent

        var environment = transport.defaultEnvironment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lithe"

        do {
            try transport.start(
                workingDirectory: workspaceURL.path,
                shellPath: shell,
                environment: environment
            )
            isRunning = transport.isRunning
            isReady = isRunning
        } catch {
            isRunning = false
            isReady = false
            startedAt = nil
            endedAt = Date()
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
        guard let data = input.data(using: .utf8) else { return }
        try? transport.send(data)
    }

    func interrupt() {
        guard isRunning else { return }
        try? transport.interrupt()
    }

    func clear() {
        transport.clear()
    }

    func focus() {
        transport.focus()
    }

    func stop() {
        transport.stop()
        isRunning = false
        isReady = false
        if startedAt != nil {
            endedAt = Date()
        }
    }

    private func updateCurrentDirectory(_ rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return }
        if let url = URL(string: rawValue), url.isFileURL {
            currentDirectory = url.standardizedFileURL
        } else if rawValue.hasPrefix("/") {
            currentDirectory = URL(fileURLWithPath: rawValue).standardizedFileURL
        }
    }

}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
