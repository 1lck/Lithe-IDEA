import Foundation

/// Stable descriptor for one document encoding.
package struct DocumentEncodingDescriptor: Sendable {
    package let id: DocumentEncoding
    package let stableID: String
    package let displayName: String
    package let aliases: [String]
    package let supportsRead: Bool
    package let supportsWrite: Bool
    package let bom: DocumentEncodingBOM

    package init(
        id: DocumentEncoding,
        stableID: String,
        displayName: String,
        aliases: [String] = [],
        supportsRead: Bool = true,
        supportsWrite: Bool = true,
        bom: DocumentEncodingBOM = .none
    ) {
        self.id = id
        self.stableID = stableID
        self.displayName = displayName
        self.aliases = aliases
        self.supportsRead = supportsRead
        self.supportsWrite = supportsWrite
        self.bom = bom
    }
}

package enum DocumentEncodingBOM: String, Codable, Sendable {
    case none
    case utf8
}

/// Stable encoding IDs shared by native adapters and the editor UI.
///
/// Additions must also be registered in ``catalog`` and mapped by each native
/// adapter. The raw values are persistence and command-palette identifiers.
package enum DocumentEncoding: String, CaseIterable, Codable, Sendable {
    case utf8 = "utf-8"
    case utf8Bom = "utf-8-bom"
    case gbk
    case gb18030
    case shiftJIS = "shift-jis"
    case windows1252 = "windows-1252"

    package static let catalog: [DocumentEncodingDescriptor] = [
        .init(id: .utf8, stableID: "utf-8", displayName: "UTF-8", aliases: ["utf8"]),
        .init(id: .utf8Bom, stableID: "utf-8-bom", displayName: "UTF-8 with BOM", aliases: ["utf8-bom", "utf-8-bom"], bom: .utf8),
        .init(id: .gbk, stableID: "gbk", displayName: "GBK", aliases: ["cp936"]),
        .init(id: .gb18030, stableID: "gb18030", displayName: "GB18030"),
        .init(id: .shiftJIS, stableID: "shift-jis", displayName: "Shift JIS", aliases: ["shift-jis", "shift_jis"]),
        .init(id: .windows1252, stableID: "windows-1252", displayName: "Windows-1252", aliases: ["cp1252"]),
    ]

    package var descriptor: DocumentEncodingDescriptor {
        Self.catalog.first { $0.id == self }!
    }

    package var displayName: String { descriptor.displayName }
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

/// Watcher reads compare raw bytes before decoding; explicit opens always decode.
package enum DocumentChangeReadResult: Sendable {
    case unchanged
    case missing
    case changed(DocumentReadDetails)
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
    func readDocumentChangeAsync(from url: URL, encoding: DocumentEncoding?, knownIdentity: String?) async throws -> DocumentChangeReadResult
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

    func readDocumentChangeAsync(from url: URL, encoding: DocumentEncoding?, knownIdentity: String?) async throws -> DocumentChangeReadResult {
        guard let details = try await readDocumentDetailsAsync(from: url, encoding: encoding) else { return .missing }
        if let knownIdentity, details.identity == knownIdentity { return .unchanged }
        return .changed(details)
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
