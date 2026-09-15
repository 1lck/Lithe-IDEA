import Foundation

package protocol WorkspaceFileOperations: Sendable {
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
    func observeDocuments(at urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void) -> any DocumentFileObservation
    func readDocumentText(from url: URL) throws -> String?
    func readDocumentTextAsync(from url: URL) async throws -> String?
    func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?) async throws -> DocumentWriteResult
    func writeDocumentText(_ text: String, to url: URL, expectedContent: String?) throws -> DocumentWriteResult
}

/// Native persistence result. Conflict preserves both the disk and editor versions.
package enum DocumentWriteResult: Sendable {
    case saved
    case conflict(String?)
}

package protocol DocumentFileObservation: Sendable { func cancel() }
private struct EmptyDocumentFileObservation: DocumentFileObservation { func cancel() {} }

package extension WorkspaceFileOperations {
    func readDocumentTextAsync(from url: URL) async throws -> String? { try readDocumentText(from: url) }
    func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?) async throws -> DocumentWriteResult {
        try writeDocumentText(text, to: url, expectedContent: expectedContent)
    }
    func observeDocuments(at urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void) -> any DocumentFileObservation {
        EmptyDocumentFileObservation()
    }
    func readDocumentText(from url: URL) throws -> String? { try readText(from: url) }
    /// Adapters must opt in; an unsupported adapter must not fall back to an unchecked write.
    func writeDocumentText(_ text: String, to url: URL, expectedContent: String?) throws -> DocumentWriteResult {
        throw CocoaError(.featureUnsupported)
    }
}
