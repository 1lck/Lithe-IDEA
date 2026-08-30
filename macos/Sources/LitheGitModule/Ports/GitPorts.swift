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

/// Everything a host needs to rebuild a deleted tag later: the record is kept
/// in session state only, and restores replay `createTag` with these values.
public struct GitTagDeletion: Equatable, Sendable {
    public let name: String
    /// The commit the deleted ref resolved to (peeled for annotated tags).
    public let deletedTarget: String
    /// `lightweight` or `annotated`, taken from the tag object type.
    public let kind: String
    /// Original annotation, if any; lightweight tags carry `nil`.
    public let message: String?

    public init(name: String, deletedTarget: String, kind: String, message: String?) {
        self.name = name
        self.deletedTarget = deletedTarget
        self.kind = kind
        self.message = message
    }

    public var isAnnotated: Bool { kind == "annotated" }
}

/// A deleted local branch and the commit it pointed at, kept in session state
/// so the host can offer a restore.
public struct GitBranchDeletion: Equatable, Sendable {
    public let name: String
    public let deletedTarget: String

    public init(name: String, deletedTarget: String) {
        self.name = name
        self.deletedTarget = deletedTarget
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
    public let tagDeletion: GitTagDeletion?
    public let branchDeletion: GitBranchDeletion?
    public init(
        arguments: [String] = [],
        output: String,
        standardOutput: String? = nil,
        standardError: String? = nil,
        exitCode: Int32,
        invocations: [GitProcessInvocation] = [],
        operationErrorMessage: String? = nil,
        stashRestoreConflict: GitStashRestoreConflict? = nil,
        tagDeletion: GitTagDeletion? = nil,
        branchDeletion: GitBranchDeletion? = nil
    ) {
        self.arguments = arguments
        self.output = output
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.invocations = invocations
        self.operationErrorMessage = operationErrorMessage
        self.stashRestoreConflict = stashRestoreConflict
        self.tagDeletion = tagDeletion
        self.branchDeletion = branchDeletion
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
