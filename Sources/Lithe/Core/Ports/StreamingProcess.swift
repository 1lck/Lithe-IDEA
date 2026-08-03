import Foundation

protocol StreamingProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    var onOutput: (@Sendable (String) -> Void)? { get set }
    var onTermination: (@Sendable (Int32) -> Void)? { get set }

    func start(_ request: ProcessRequest) throws
    func send(_ input: Data) throws
    func stop()
}
