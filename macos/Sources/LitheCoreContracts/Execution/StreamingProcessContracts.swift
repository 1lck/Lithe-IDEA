import Foundation

package struct ProcessRequest: Sendable {
    package let operationID: String?
    package let executablePath: String
    package let arguments: [String]
    package let workingDirectory: String?
    package let environment: [String: String]?
    package let standardInput: Data?
    package let keepsStandardInputOpen: Bool
    package let timeoutMilliseconds: Int?

    package init(
        operationID: String? = nil,
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        keepsStandardInputOpen: Bool = false,
        timeoutMilliseconds: Int? = nil
    ) {
        self.operationID = operationID
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.keepsStandardInputOpen = keepsStandardInputOpen
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

package enum ProcessLifecycleState: String, Sendable {
    case starting
    case running
    case stopping
    case finished
    case failed
}

package struct ProcessLifecycleEvent: Sendable {
    package let operationID: String?
    package let state: ProcessLifecycleState
    package let exitCode: Int32?
    package let message: String?

    package init(
        operationID: String?,
        state: ProcessLifecycleState,
        exitCode: Int32?,
        message: String?
    ) {
        self.operationID = operationID
        self.state = state
        self.exitCode = exitCode
        self.message = message
    }
}

package protocol StreamingProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    var onOutput: (@Sendable (String) -> Void)? { get set }
    var onTermination: (@Sendable (Int32) -> Void)? { get set }
    var onStateChange: (@Sendable (ProcessLifecycleEvent) -> Void)? { get set }

    func start(_ request: ProcessRequest) throws
    func send(_ input: Data) throws
    func stop()
}
