import Foundation

public struct GitProcessResult: Sendable {
    public let arguments: [String]
    public let output: String
    public let exitCode: Int32
    public let stashRestoreConflict: GitStashRestoreConflict?
    public init(
        arguments: [String] = [],
        output: String,
        exitCode: Int32,
        stashRestoreConflict: GitStashRestoreConflict? = nil
    ) {
        self.arguments = arguments
        self.output = output
        self.exitCode = exitCode
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
