import Foundation

protocol WorkspaceFileOperations: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func createFile(at url: URL) throws
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func trashItem(at url: URL) throws
    func writeText(_ text: String, to url: URL) throws
    func readText(from url: URL) throws -> String
}
