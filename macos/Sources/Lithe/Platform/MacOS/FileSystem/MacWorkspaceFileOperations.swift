import Foundation
import Darwin
import LitheModuleAPI

struct MacWorkspaceFileOperations: WorkspaceFileOperations {
    private let moveToTrash: @Sendable (URL) throws -> URL

    init(moveToTrash: @escaping @Sendable (URL) throws -> URL = { try MacWorkspaceFileOperations.systemTrash($0) }) {
        self.moveToTrash = moveToTrash
    }

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

    func writeDocumentTextAsync(
        _ text: String, to url: URL, expectedContent: String?,
        encoding: DocumentEncoding, expectedIdentity: String?,
        hardLinkAuthorization: DocumentHardLinkAuthorization
    ) async throws -> EncodedDocumentWriteResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.documentQueue.async {
                continuation.resume(with: Result {
                    try self.writeDocumentText(text, to: url, expectedContent: expectedContent,
                        encoding: encoding, expectedIdentity: expectedIdentity,
                        hardLinkAuthorization: hardLinkAuthorization)
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

    private struct Snapshot {
        let bytes: Data
        let targetIdentity: String
        let isHardLinked: Bool
    }

    private func readDocumentBytes(from url: URL, requiresSingleLink: Bool = false) throws -> Data? {
        try readSnapshot(from: url, requiresSingleLink: requiresSingleLink)?.bytes
    }

    private func readSnapshot(from url: URL, requiresSingleLink: Bool = false) throws -> Snapshot? {
        // O_NOFOLLOW prevents a symlink swap; O_NONBLOCK prevents a replaced FIFO
        // from hanging the document queue before fstat can reject it.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw DocumentFileAccessError.symbolicLink }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let info = try documentInfo(descriptor)
        if requiresSingleLink, info.st_nlink != 1 { throw DocumentFileAccessError.hardLinkMutationUnsupported }
        let bytes = try handle.read(upToCount: Self.maxDocumentBytes + 1) ?? Data()
        guard bytes.count <= Self.maxDocumentBytes else { throw CocoaError(.fileReadTooLarge) }
        return Snapshot(bytes: bytes, targetIdentity: targetIdentity(info), isHardLinked: info.st_nlink > 1)
    }

    private func documentInfo(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        if info.st_mode & S_IFMT == S_IFDIR { throw DocumentFileAccessError.directory }
        guard info.st_mode & S_IFMT == S_IFREG else { throw DocumentFileAccessError.notRegularFile }
        guard info.st_size <= Self.maxDocumentBytes else { throw CocoaError(.fileReadTooLarge) }
        return info
    }

    private func targetIdentity(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_nlink)"
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
        try writeDocumentText(text, to: url, expectedContent: expectedContent,
            encoding: encoding, expectedIdentity: expectedIdentity, hardLinkAuthorization: nil)
    }

    func writeDocumentText(
        _ text: String, to url: URL, expectedContent: String?,
        encoding: DocumentEncoding, expectedIdentity: String?,
        hardLinkAuthorization: DocumentHardLinkAuthorization?
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
            let current = try readSnapshot(from: url)
            guard matches(current?.bytes) else { return conflict(current?.bytes) }
            func validateConsent(_ snapshot: Snapshot?) throws {
                if let authorization = hardLinkAuthorization {
                    guard snapshot?.targetIdentity == authorization.targetIdentity else {
                        throw DocumentFileAccessError.hardLinkChanged
                    }
                } else if let snapshot, snapshot.isHardLinked {
                    throw DocumentHardLinkConfirmationRequired(targetIdentity: snapshot.targetIdentity)
                }
            }
            try validateConsent(current)
            if let authorization = hardLinkAuthorization, authorization.mode == .updateLinkedFile {
                return try writeLinkedFile(data, at: url, authorization: authorization,
                    matches: matches, conflict: conflict)
            }
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
            let latest = try readSnapshot(from: url)
            guard matches(latest?.bytes) else { return conflict(latest?.bytes) }
            try validateConsent(latest)
            guard current?.targetIdentity == latest?.targetIdentity else { throw DocumentFileAccessError.hardLinkChanged }
            if current == nil {
                // A hard link fails if another writer created the destination after our check.
                try FileManager.default.linkItem(at: temporary, to: url)
            } else {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            }
            return .saved(identity: MacDocumentEncoding.identity(data))
        }
    }

    private func writeLinkedFile(
        _ data: Data, at url: URL, authorization: DocumentHardLinkAuthorization,
        matches: (Data?) -> Bool, conflict: (Data?) -> EncodedDocumentWriteResult
    ) throws -> EncodedDocumentWriteResult {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        // Advisory only: unrelated external writers do not participate in this lock.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = flock(descriptor, LOCK_UN) }
        let info = try documentInfo(descriptor)
        guard targetIdentity(info) == authorization.targetIdentity else { throw DocumentFileAccessError.hardLinkChanged }
        let current = try handle.read(upToCount: Self.maxDocumentBytes + 1) ?? Data()
        guard current.count <= Self.maxDocumentBytes else { throw CocoaError(.fileReadTooLarge) }
        guard matches(current) else { return conflict(current) }
        let latest = try readSnapshot(from: url)
        guard latest?.targetIdentity == authorization.targetIdentity else { throw DocumentFileAccessError.hardLinkChanged }
        guard matches(latest?.bytes) else { return conflict(latest?.bytes) }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
        } catch {
            // Do not attempt a destructive rollback over another writer. Keep the
            // editor draft and explicitly report that shared bytes may be partial.
            throw DocumentFileAccessError.inPlaceWriteFailed
        }
        return .saved(identity: MacDocumentEncoding.identity(data))
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

    func trashDocument(at url: URL, expectedIdentity: String) throws -> DocumentTrashResult {
        try Self.documentWriteLock.withLock {
            guard let current = try readDocumentBytes(from: url, requiresSingleLink: true),
                  MacDocumentEncoding.identity(current) == expectedIdentity else { return .conflict }
            let trashed = try moveToTrash(url)
            // External writers do not participate in our save lock. Validate the
            // actual moved object, including link/type checks, then recover it on
            // conflict. Never overwrite a file concurrently recreated at `url`.
            let moved: Data?
            do { moved = try readDocumentBytes(from: trashed, requiresSingleLink: true) }
            catch {
                try restoreTrashedItem(trashed, to: url)
                throw error
            }
            guard let moved, MacDocumentEncoding.identity(moved) == expectedIdentity else {
                try restoreTrashedItem(trashed, to: url)
                return .conflict
            }
            return .trashed
        }
    }

    private func restoreTrashedItem(_ trashed: URL, to original: URL) throws {
        do { try FileManager.default.moveItem(at: trashed, to: original) }
        catch {
            // Preserve both versions if the original path has been recreated.
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: L10n.string("Rollback could not restore the changed file. It remains at \(trashed.path). Restore it manually before retrying."),
                NSUnderlyingErrorKey: error,
            ])
        }
    }

    private static func systemTrash(_ url: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        guard let resultingURL else {
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSLocalizedDescriptionKey: L10n.string("Rollback could not verify the moved file. Check the Trash before retrying."),
            ])
        }
        return resultingURL as URL
    }

    func writeText(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func readText(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
