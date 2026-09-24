import Foundation

/// User-visible text encodings supported by the native document adapters.
///
/// The raw values are stable persistence and command-palette identifiers. The
/// platform adapters own the actual byte conversion implementation.
package enum DocumentEncoding: String, CaseIterable, Codable, Sendable {
    case utf8 = "utf-8"
    case utf8Bom = "utf-8-bom"
    case gbk
    case gb18030
    case shiftJIS = "shift-jis"
    case windows1252 = "windows-1252"

    package var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8Bom: "UTF-8 with BOM"
        case .gbk: "GBK"
        case .gb18030: "GB18030"
        case .shiftJIS: "Shift JIS"
        case .windows1252: "Windows-1252"
        }
    }
}

/// A decoded file snapshot. `identity` is the SHA-256 of the original bytes.
package struct DocumentReadDetails: Sendable {
    package let text: String
    package let encoding: DocumentEncoding
    package let identity: String?

    package init(text: String, encoding: DocumentEncoding, identity: String? = nil) {
        self.text = text
        self.encoding = encoding
        self.identity = identity
    }
}

package protocol WorkspaceFileOperations: Sendable {
    var supportsDocumentEncoding: Bool { get }
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
    func readDocumentDetails(from url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails?
    func readDocumentDetailsAsync(from url: URL, encoding: DocumentEncoding?) async throws -> DocumentReadDetails?
    func writeDocumentText(
        _ text: String,
        to url: URL,
        expectedContent: String?,
        encoding: DocumentEncoding,
        expectedIdentity: String?
    ) throws -> EncodedDocumentWriteResult
    func writeDocumentTextAsync(
        _ text: String,
        to url: URL,
        expectedContent: String?,
        encoding: DocumentEncoding,
        expectedIdentity: String?
    ) async throws -> EncodedDocumentWriteResult
}

/// Native persistence result. Conflict preserves both the disk and editor versions.
package enum DocumentWriteResult: Sendable {
    case saved
    case conflict(String?)
}

package enum EncodedDocumentWriteResult: Sendable {
    case saved(identity: String?)
    case conflict(content: String?, identity: String?)
}

package protocol DocumentFileObservation: Sendable { func cancel() }
private struct EmptyDocumentFileObservation: DocumentFileObservation { func cancel() {} }

package extension WorkspaceFileOperations {
    var supportsDocumentEncoding: Bool { false }
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

    func readDocumentDetails(from url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails? {
        guard let text = try readDocumentText(from: url) else { return nil }
        guard encoding == nil || encoding == .utf8 else { throw CocoaError(.featureUnsupported) }
        return DocumentReadDetails(text: text, encoding: .utf8)
    }

    func readDocumentDetailsAsync(from url: URL, encoding: DocumentEncoding?) async throws -> DocumentReadDetails? {
        guard let text = try await readDocumentTextAsync(from: url) else { return nil }
        guard encoding == nil || encoding == .utf8 else { throw CocoaError(.featureUnsupported) }
        return DocumentReadDetails(text: text, encoding: .utf8)
    }

    func writeDocumentText(
        _ text: String,
        to url: URL,
        expectedContent: String?,
        encoding: DocumentEncoding,
        expectedIdentity: String?
    ) throws -> EncodedDocumentWriteResult {
        guard encoding == .utf8, expectedIdentity == nil else { throw CocoaError(.featureUnsupported) }
        switch try writeDocumentText(text, to: url, expectedContent: expectedContent) {
        case .saved: return .saved(identity: nil)
        case .conflict(let content): return .conflict(content: content, identity: nil)
        }
    }

    func writeDocumentTextAsync(
        _ text: String,
        to url: URL,
        expectedContent: String?,
        encoding: DocumentEncoding,
        expectedIdentity: String?
    ) async throws -> EncodedDocumentWriteResult {
        guard encoding == .utf8, expectedIdentity == nil else { throw CocoaError(.featureUnsupported) }
        switch try await writeDocumentTextAsync(text, to: url, expectedContent: expectedContent) {
        case .saved: return .saved(identity: nil)
        case .conflict(let content): return .conflict(content: content, identity: nil)
        }
    }
}
