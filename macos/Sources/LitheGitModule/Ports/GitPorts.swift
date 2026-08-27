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

public struct GitProcessResult: Sendable {
    public let arguments: [String]
    public let output: String
    public let standardOutput: String?
    public let standardError: String?
    public let exitCode: Int32
    public let invocations: [GitProcessInvocation]
    public let operationErrorMessage: String?
    public let stashRestoreConflict: GitStashRestoreConflict?
    public init(
        arguments: [String] = [],
        output: String,
        standardOutput: String? = nil,
        standardError: String? = nil,
        exitCode: Int32,
        invocations: [GitProcessInvocation] = [],
        operationErrorMessage: String? = nil,
        stashRestoreConflict: GitStashRestoreConflict? = nil
    ) {
        self.arguments = arguments
        self.output = output
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.invocations = invocations
        self.operationErrorMessage = operationErrorMessage
        self.stashRestoreConflict = stashRestoreConflict
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
