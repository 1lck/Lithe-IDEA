import Foundation

struct MacWorkspaceFileOperations: WorkspaceFileOperations {
    var supportsDocumentEncoding: Bool { true }
    func observeDocuments(at urls: [URL], onChange: @escaping @Sendable ([URL]) -> Void) -> any DocumentFileObservation {
        MacDocumentObservation(urls: urls, onChange: onChange)
    }

    func readDocumentTextAsync(from url: URL) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            Self.documentQueue.async { continuation.resume(with: Result { try self.readDocumentText(from: url) }) }
        }
    }

    func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?) async throws -> DocumentWriteResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.documentQueue.async { continuation.resume(with: Result { try self.writeDocumentText(text, to: url, expectedContent: expectedContent) }) }
        }
    }

    private static let documentQueue = DispatchQueue(label: "app.lithe.document-files", qos: .userInitiated)
    private static let documentWriteLock = NSLock()
    private static let maxDocumentBytes = 32 * 1024 * 1024

    func readDocumentDetailsAsync(from url: URL, encoding: DocumentEncoding?) async throws -> DocumentReadDetails? {
        try await withCheckedThrowingContinuation { continuation in
            Self.documentQueue.async {
                continuation.resume(with: Result { try self.readDocumentDetails(from: url, encoding: encoding) })
            }
        }
    }

    func readDocumentChangeAsync(from url: URL, encoding: DocumentEncoding?, knownIdentity: String?) async throws -> DocumentChangeReadResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.documentQueue.async {
                continuation.resume(with: Result {
                    guard let bytes = try self.readDocumentBytes(from: url) else { return .missing }
                    // Saving with another codec does not change the read selection.
                    // A delayed notification of our own write must never decode it.
                    if let knownIdentity, MacDocumentEncoding.identity(bytes) == knownIdentity { return .unchanged }
                    return .changed(try MacDocumentEncoding.decode(bytes, encoding: encoding))
                })
            }
        }
    }

    func writeDocumentTextAsync(
        _ text: String, to url: URL, expectedContent: String?,
        encoding: DocumentEncoding, expectedIdentity: String?
    ) async throws -> EncodedDocumentWriteResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.documentQueue.async {
                continuation.resume(with: Result {
                    try self.writeDocumentText(text, to: url, expectedContent: expectedContent,
                                               encoding: encoding, expectedIdentity: expectedIdentity)
                })
            }
        }
    }

    func readDocumentText(from url: URL) throws -> String? {
        try readDocumentDetails(from: url, encoding: nil)?.text
    }

    func readDocumentDetails(from url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails? {
        try readDocumentBytes(from: url).map { try MacDocumentEncoding.decode($0, encoding: encoding) }
    }

    private func readDocumentBytes(from url: URL) throws -> Data? {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values: URLResourceValues
        do { values = try freshURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.linkCount ?? 1) == 1 else { throw CocoaError(.featureUnsupported) }
        guard (values.fileSize ?? 0) <= Self.maxDocumentBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maxDocumentBytes + 1) ?? Data()
        guard bytes.count <= Self.maxDocumentBytes else { throw CocoaError(.fileReadTooLarge) }
        return bytes
    }

    func writeDocumentText(_ text: String, to url: URL, expectedContent: String?) throws -> DocumentWriteResult {
        switch try writeDocumentText(text, to: url, expectedContent: expectedContent, encoding: .utf8, expectedIdentity: nil) {
        case .saved: return .saved
        case .conflict(let content, _): return .conflict(content)
        }
    }

    func writeDocumentText(
        _ text: String, to url: URL, expectedContent: String?,
        encoding: DocumentEncoding, expectedIdentity: String?
    ) throws -> EncodedDocumentWriteResult {
        try Self.documentWriteLock.withLock {
            // Conversion must succeed before creating any staging file.
            let data = try MacDocumentEncoding.encode(text, encoding: encoding)
            guard data.count <= Self.maxDocumentBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            func matches(_ bytes: Data?) -> Bool {
                if let expectedIdentity { return bytes.map(MacDocumentEncoding.identity) == expectedIdentity }
                // Compatibility callers have a UTF-8 text baseline; never interpret
                // a missing baseline as permission to overwrite an existing file.
                return bytes == expectedContent.map { Data($0.utf8) }
            }
            func conflict(_ bytes: Data?) -> EncodedDocumentWriteResult {
                .conflict(content: bytes.flatMap { try? MacDocumentEncoding.decode($0, encoding: nil).text },
                          identity: bytes.map(MacDocumentEncoding.identity))
            }
            let current = try readDocumentBytes(from: url)
            guard matches(current) else { return conflict(current) }
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".lithe-document-\(UUID().uuidString).tmp")
            defer {
                do { try FileManager.default.removeItem(at: temporary) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { }
                catch { NSLog("Could not clean document staging file: %@", error.localizedDescription) }
            }
            if current != nil {
                // Copy metadata before replacing content so permissions and extended attributes survive.
                try FileManager.default.copyItem(at: url, to: temporary)
                try data.write(to: temporary)
            } else { try data.write(to: temporary, options: .withoutOverwriting) }
            let latest = try readDocumentBytes(from: url)
            guard matches(latest) else { return conflict(latest) }
            if current == nil {
                // A hard link fails if another writer created the destination after our check.
                try FileManager.default.linkItem(at: temporary, to: url)
            } else {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            }
            return .saved(identity: MacDocumentEncoding.identity(data))
        }
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func createFile(at url: URL) throws {
        try Data().write(to: url, options: .withoutOverwriting)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func readText(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
