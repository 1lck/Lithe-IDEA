import Foundation

enum RawProcessSessionError: LocalizedError, Equatable, Sendable {
    case notRunning
    case standardInputUnavailable

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "The process is not running."
        case .standardInputUnavailable:
            "The process does not have an open standard-input pipe."
        }
    }
}

protocol RawProcessSession: AnyObject, Sendable {
    var isRunning: Bool { get }
    var onOutput: (@Sendable (Data) -> Void)? { get set }
    var onError: (@Sendable (Data) -> Void)? { get set }
    var onTermination: (@Sendable (Int32) -> Void)? { get set }
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)? { get set }

    func start(_ request: ProcessRequest) throws
    func send(_ input: Data) throws
    func stop()
}
