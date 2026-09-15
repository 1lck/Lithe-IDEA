import Foundation

struct MacWorkspaceFileOperations: WorkspaceFileOperations {
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

    func readDocumentText(from url: URL) throws -> String? {
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .linkCountKey]) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.linkCount ?? 1) == 1 else { throw CocoaError(.featureUnsupported) }
        guard (values.fileSize ?? 0) <= Self.maxDocumentBytes else { throw CocoaError(.fileReadTooLarge) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maxDocumentBytes + 1) ?? Data()
        guard bytes.count <= Self.maxDocumentBytes else { throw CocoaError(.fileReadTooLarge) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return text
    }

    func writeDocumentText(_ text: String, to url: URL, expectedContent: String?) throws -> DocumentWriteResult {
        try Self.documentWriteLock.withLock {
            let data = Data(text.utf8)
            guard data.count <= Self.maxDocumentBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            let current = try readDocumentText(from: url)
            guard current.map({ Data($0.utf8) }) == expectedContent.map({ Data($0.utf8) }) else { return .conflict(current) }
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
            let latest = try readDocumentText(from: url)
            guard latest.map({ Data($0.utf8) }) == expectedContent.map({ Data($0.utf8) }) else { return .conflict(latest) }
            if expectedContent == nil {
                // A hard link fails if another writer created the destination after our check.
                try FileManager.default.linkItem(at: temporary, to: url)
            } else {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            }
            return .saved
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
