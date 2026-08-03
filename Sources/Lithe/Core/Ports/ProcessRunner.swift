import Foundation

struct ProcessRequest: Sendable {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String: String]?
    let standardInput: Data?
    let keepsStandardInputOpen: Bool

    init(
        executablePath: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        keepsStandardInputOpen: Bool = false
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.keepsStandardInputOpen = keepsStandardInputOpen
    }
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
