import Foundation

public struct GitProcessInvocation: Equatable, Sendable {
    public let arguments: [String]
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32

    public init(
        arguments: [String],
        standardOutput: String,
        standardError: String,
        exitCode: Int32
    ) {
        self.arguments = arguments
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    public var output: String { standardOutput + standardError }
}

public struct GitOperationWarning: Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: String?

    public init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct GitProcessResult: Sendable {
    public let arguments: [String]
    public let output: String
    public let standardOutput: String?
    public let standardError: String?
    public let exitCode: Int32
    public let invocations: [GitProcessInvocation]
    public let operationErrorMessage: String?
    public let stashRestoreConflict: GitStashRestoreConflict?
    public let warnings: [GitOperationWarning]
    public init(
        arguments: [String] = [],
        output: String,
        standardOutput: String? = nil,
        standardError: String? = nil,
        exitCode: Int32,
        invocations: [GitProcessInvocation] = [],
        operationErrorMessage: String? = nil,
        stashRestoreConflict: GitStashRestoreConflict? = nil,
        warnings: [GitOperationWarning] = []
    ) {
        self.arguments = arguments
        self.output = output
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.invocations = invocations
        self.operationErrorMessage = operationErrorMessage
        self.stashRestoreConflict = stashRestoreConflict
        self.warnings = warnings
    }
}

public protocol GitShelfStorage: Sendable {
    func applicationSupportDirectory() -> URL
    func fileExists(at url: URL) -> Bool
    func listDirectory(at url: URL) -> [URL]
    func readData(from url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func createDirectory(at url: URL) throws
    func removeItem(at url: URL) throws
}
