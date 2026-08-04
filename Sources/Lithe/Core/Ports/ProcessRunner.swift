import Foundation

struct ProcessRequest: Sendable {
    let operationID: String?
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String: String]?
    let standardInput: Data?
    let keepsStandardInputOpen: Bool
    let timeoutMilliseconds: Int?

    init(
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

enum ProcessLifecycleState: String, Sendable {
    case starting
    case running
    case stopping
    case finished
    case failed
}

struct ProcessLifecycleEvent: Sendable {
    let operationID: String?
    let state: ProcessLifecycleState
    let exitCode: Int32?
    let message: String?
}

struct ProcessResult: Sendable {
    let output: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
}

protocol ProcessRunner: Sendable {
    func run(_ request: ProcessRequest) -> ProcessResult
}

protocol GitCommandRunner: Sendable {
    func run(
        arguments: [String],
        workingDirectory: String,
        input: String?
    ) -> ProcessResult
}
