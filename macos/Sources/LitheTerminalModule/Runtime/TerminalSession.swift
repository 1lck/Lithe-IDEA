import Combine
import Foundation

@MainActor
public final class TerminalSession: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public private(set) var isRunning = false
    @Published public private(set) var isReady = false
    @Published public private(set) var isManagedProcess = false
    @Published public private(set) var shellName = "Shell"
    @Published public private(set) var processTitle: String?
    @Published public private(set) var currentDirectory: URL?
    @Published public private(set) var lastExitCode: Int32?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var endedAt: Date?
    public var onLink: ((String, [String: String]) -> Void)?
    /// Receives decoded child-process output without taking ownership of the
    /// terminal surface.
    public var onOutput: ((String) -> Void)?

    private let transport: any TerminalTransport
    private var workspaceURL: URL?
    private var selectedShellPath: String?

    public init(transport: any TerminalTransport) {
        self.transport = transport
        transport.onTermination = { [weak self] exitCode in
            guard let self else { return }
            isRunning = false; isReady = false; lastExitCode = exitCode; endedAt = Date()
        }
        transport.onOutput = { [weak self] data in
            guard let self, !data.isEmpty else { return }
            self.onOutput?(String(decoding: data, as: UTF8.self))
        }
        transport.onTitle = { [weak self] title in
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.processTitle = value.isEmpty ? nil : value
        }
        transport.onDirectoryUpdate = { [weak self] in self?.updateCurrentDirectory($0) }
        transport.onLink = { [weak self] link, params in self?.onLink?(link, params) }
    }

    public var nativeView: AnyObject { transport.nativeView }
    public var displayTitle: String { processTitle?.isEmpty == false ? processTitle! : shellName }
    public var displayDirectory: String? { currentDirectory?.lastPathComponent.nonEmpty }

    public func elapsedDescription(at date: Date = Date()) -> String? {
        guard let startedAt else { return nil }
        let seconds = Int(max(0, (endedAt ?? date).timeIntervalSince(startedAt)).rounded(.down))
        let hours = seconds / 3_600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, (seconds % 3_600) / 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    public func start(in workspaceURL: URL, shellPath: String? = nil) {
        stop()
        self.workspaceURL = workspaceURL
        isManagedProcess = false
        currentDirectory = workspaceURL.standardizedFileURL
        processTitle = nil; lastExitCode = nil; startedAt = Date(); endedAt = nil
        let shell = shellPath ?? selectedShellPath ?? transport.defaultShellPath()
        selectedShellPath = shell
        shellName = URL(fileURLWithPath: shell).lastPathComponent
        let environment = terminalEnvironment()
        do {
            try transport.start(workingDirectory: workspaceURL.path, shellPath: shell, environment: environment)
            isRunning = transport.isRunning; isReady = isRunning
        } catch {
            isRunning = false; isReady = false; startedAt = nil; endedAt = Date()
        }
    }

    @discardableResult
    public func startProcess(_ launch: TerminalProcessLaunch) throws -> Int32 {
        stop()
        let workingDirectory = URL(
            fileURLWithPath: launch.workingDirectory,
            isDirectory: true
        ).standardizedFileURL
        workspaceURL = workingDirectory
        selectedShellPath = nil
        isManagedProcess = true
        currentDirectory = workingDirectory
        processTitle = launch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if processTitle?.isEmpty == true { processTitle = nil }
        lastExitCode = nil
        startedAt = Date()
        endedAt = nil
        shellName = URL(fileURLWithPath: launch.executablePath).lastPathComponent

        do {
            let processID = try transport.startProcess(
                launch,
                environment: terminalEnvironment(applying: launch.environmentChanges)
            )
            isRunning = transport.isRunning
            isReady = isRunning
            return processID
        } catch {
            isRunning = false
            isReady = false
            startedAt = nil
            endedAt = Date()
            throw error
        }
    }

    public func restart() {
        guard !isManagedProcess, let workspaceURL else { return }
        start(in: workspaceURL, shellPath: selectedShellPath)
    }
    public func restart(using shellPath: String) {
        guard !isManagedProcess, let workspaceURL else { return }
        start(in: workspaceURL, shellPath: shellPath)
    }
    public func send(_ command: String) { sendInput(command + "\n") }
    public func sendInput(_ input: String) {
        guard isRunning, isReady, let data = input.data(using: .utf8) else { return }
        try? transport.send(data)
    }
    public func interrupt() { if isRunning { try? transport.interrupt() } }
    public func clear() { transport.clear() }
    public func focus() { transport.focus() }
    public func stop() {
        transport.stop(); isRunning = false; isReady = false
        if startedAt != nil { endedAt = Date() }
    }

    private func updateCurrentDirectory(_ rawValue: String?) {
        guard let rawValue, !rawValue.isEmpty else { return }
        if let url = URL(string: rawValue), url.isFileURL { currentDirectory = url.standardizedFileURL }
        else if rawValue.hasPrefix("/") { currentDirectory = URL(fileURLWithPath: rawValue).standardizedFileURL }
    }

    private func terminalEnvironment(
        applying changes: [TerminalEnvironmentChange] = []
    ) -> [String: String] {
        var environment = transport.defaultEnvironment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lithe"
        for change in changes {
            if let value = change.value {
                environment[change.name] = value
            } else {
                environment[change.name] = nil
            }
        }
        return environment
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
