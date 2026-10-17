import Foundation

public struct TerminalEnvironmentChange: Equatable, Sendable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

/// Direct process launch for a PTY-backed terminal. Arguments stay separated
/// so callers never need to build a shell command string.
public struct TerminalProcessLaunch: Equatable, Sendable {
    public let title: String?
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let environmentChanges: [TerminalEnvironmentChange]

    public init(
        title: String?,
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        environmentChanges: [TerminalEnvironmentChange] = []
    ) {
        self.title = title
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentChanges = environmentChanges
    }
}

/// A program started from a terminal that is still running, reported per job
/// (process group). Used to ask the user before the terminal is closed.
public struct TerminalRunningProgram: Equatable, Sendable, Identifiable {
    public let processID: Int32
    public let commandLine: String
    public let listeningPorts: [Int]
    public let startedAt: Date?

    public var id: Int32 { processID }

    public init(processID: Int32, commandLine: String, listeningPorts: [Int] = [], startedAt: Date? = nil) {
        self.processID = processID
        self.commandLine = commandLine
        self.listeningPorts = listeningPorts
        self.startedAt = startedAt
    }
}

/// Platform terminal runtime injected by the native composition root.
@MainActor
public protocol TerminalTransport: AnyObject {
    var isRunning: Bool { get }
    var processID: Int32? { get }
    var shellName: String { get }
    var nativeView: AnyObject { get }
    var onTermination: ((Int32?) -> Void)? { get set }
    /// Raw bytes received from the child process before terminal emulation.
    /// Hosts may mirror this output into another product surface.
    var onOutput: ((Data) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    var onDirectoryUpdate: ((String?) -> Void)? { get set }
    var onLink: ((String, [String: String]) -> Void)? { get set }

    func defaultShellPath() -> String
    func defaultEnvironment() -> [String: String]
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws
    func startProcess(_ launch: TerminalProcessLaunch, environment: [String: String]) throws -> Int32
    func send(_ input: Data) throws
    func interrupt() throws
    func focus()
    func clear()
    /// Starts stopping every process of the terminal session, including jobs
    /// in their own process groups and jobs that outlived the shell.
    func stop()
    /// Stops like `stop()` and returns once the session's processes are gone
    /// or the bounded forced-termination phase has ended.
    func stopAndWait() async
    /// Programs other than an interactive shell that still run in this
    /// terminal's session, even after the shell itself has exited.
    func runningPrograms() -> [TerminalRunningProgram]
}

public extension TerminalTransport {
    func stopAndWait() async { stop() }
    func runningPrograms() -> [TerminalRunningProgram] { [] }
}
