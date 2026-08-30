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

/// Platform terminal runtime injected by the native composition root.
@MainActor
public protocol TerminalTransport: AnyObject {
    var isRunning: Bool { get }
    var processID: Int32? { get }
    var shellName: String { get }
    var nativeView: AnyObject { get }
    var onTermination: ((Int32?) -> Void)? { get set }
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
    func stop()
}
