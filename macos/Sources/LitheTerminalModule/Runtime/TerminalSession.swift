import Combine
import Foundation

@MainActor
public final class TerminalSession: ObservableObject, Identifiable {
    public let id = UUID()
    @Published public private(set) var isRunning = false
    @Published public private(set) var isReady = false
    @Published public private(set) var shellName = "Shell"
    @Published public private(set) var processTitle: String?
    @Published public private(set) var currentDirectory: URL?
    @Published public private(set) var lastExitCode: Int32?
    @Published public private(set) var startedAt: Date?
    @Published public private(set) var endedAt: Date?
    public var onLink: ((String, [String: String]) -> Void)?

    private let transport: any TerminalTransport
    private var workspaceURL: URL?
    private var selectedShellPath: String?

    public init(transport: any TerminalTransport) {
        self.transport = transport
        transport.onTermination = { [weak self] exitCode in
            guard let self else { return }
            isRunning = false; isReady = false; lastExitCode = exitCode; endedAt = Date()
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
        currentDirectory = workspaceURL.standardizedFileURL
        processTitle = nil; lastExitCode = nil; startedAt = Date(); endedAt = nil
        let shell = shellPath ?? selectedShellPath ?? transport.defaultShellPath()
        selectedShellPath = shell
        shellName = URL(fileURLWithPath: shell).lastPathComponent
        var environment = transport.defaultEnvironment()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Lithe"
        do {
            try transport.start(workingDirectory: workspaceURL.path, shellPath: shell, environment: environment)
            isRunning = transport.isRunning; isReady = isRunning
        } catch {
            isRunning = false; isReady = false; startedAt = nil; endedAt = Date()
        }
    }

    public func restart() { if let workspaceURL { start(in: workspaceURL, shellPath: selectedShellPath) } }
    public func restart(using shellPath: String) { if let workspaceURL { start(in: workspaceURL, shellPath: shellPath) } }
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
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
