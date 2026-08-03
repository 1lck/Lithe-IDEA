import Foundation

protocol TerminalTransport: AnyObject, Sendable {
    var onOutput: (@Sendable (String) -> Void)? { get set }
    var onTermination: (@Sendable () -> Void)? { get set }

    func defaultShellPath() -> String
    func defaultEnvironment() -> [String: String]
    func start(
        workingDirectory: String,
        shellPath: String,
        environment: [String: String]
    ) throws
    func send(_ input: Data) throws
    func interrupt() throws
    func stop()
}
