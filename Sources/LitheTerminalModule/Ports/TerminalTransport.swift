import Foundation

/// Platform terminal runtime injected by the native composition root.
@MainActor
public protocol TerminalTransport: AnyObject {
    var isRunning: Bool { get }
    var shellName: String { get }
    var nativeView: AnyObject { get }
    var onTermination: ((Int32?) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    var onDirectoryUpdate: ((String?) -> Void)? { get set }
    var onLink: ((String, [String: String]) -> Void)? { get set }

    func defaultShellPath() -> String
    func defaultEnvironment() -> [String: String]
    func start(workingDirectory: String, shellPath: String, environment: [String: String]) throws
    func send(_ input: Data) throws
    func interrupt() throws
    func focus()
    func clear()
    func stop()
}
