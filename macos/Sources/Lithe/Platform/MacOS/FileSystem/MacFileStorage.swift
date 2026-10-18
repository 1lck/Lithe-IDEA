import Darwin
import Foundation

struct MacFileStorage: FileStorage {
    let identity: MacAppIdentity

    init(identity: MacAppIdentity = MacAppIdentity()) {
        self.identity = identity
    }

    func homeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    func cacheDirectory() -> URL {
        identity.storageRoot(FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory)
    }

    func applicationSupportDirectory() -> URL {
        identity.storageRoot(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory)
    }

    func temporaryDirectory() -> URL {
        let root = identity.storageRoot(FileManager.default.temporaryDirectory)
        // Consumers write individual files directly into this nonthrowing port.
        // If creation fails, their write reports the underlying filesystem error.
        if identity.isDevelopment {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    func metadata(for url: URL) -> FileMetadata? {
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        guard let values = try? freshURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isRegularFileKey,
            .isDirectoryKey,
            .isWritableKey
        ]) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: freshURL.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        // `isWritable` accounts for ACL/current-user access. The mode-bit check
        // also preserves the product's explicit read-only behavior when tests or
        // privileged processes could technically replace a 0444 file.
        let hasWritableMode = permissions.map { $0 & 0o222 != 0 } ?? true
        return FileMetadata(
            byteCount: values.fileSize,
            modificationDate: values.contentModificationDate,
            isRegularFile: values.isRegularFile == true,
            isDirectory: values.isDirectory == true,
            isWritable: values.isWritable == true && hasWritableMode
        )
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func listDirectory(at url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    func readPrefix(from url: URL, byteCount: Int) throws -> Data {
        precondition(byteCount >= 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: byteCount) ?? Data()
    }

    func readData(from url: URL, options: Data.ReadingOptions = []) throws -> Data {
        try Data(contentsOf: url, options: options)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        try data.write(to: url, options: options)
    }

    /// Prepares the bytes beside the destination, then publishes them through
    /// an atomic filesystem exchange so the version that was actually replaced
    /// can be compared with the planned snapshot. A plain "compare, then
    /// rename" still overwrites a save another program made in between.
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).lithe-\(UUID().uuidString)"
        )
        try data.write(to: temporary)
        var removeTemporary = true
        defer { if removeTemporary { try? FileManager.default.removeItem(at: temporary) } }

        guard let expected else {
            // Publish without replacing a file another process just created.
            guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { return false }
                if renameIsUnsupported() {
                    return try publishNewFileWithoutExchange(data, at: url)
                }
                throw CocoaError(.fileWriteUnknown)
            }
            return true
        }

        // The exchange also returns the previous contents under the temporary
        // path; comparing them with the planned snapshot is how a lost external
        // save becomes observable.
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOENT { return false }
            if renameIsUnsupported() {
                return try publishAfterCompare(data, at: url, expecting: expected)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        let matches: Bool
        do {
            matches = try snapshotMatches(at: temporary, expected: expected)
        } catch {
            let state = (try? resolveMismatch(
                data, &removeTemporary, temporary: temporary, target: url
            )) ?? .unknown
            if case .superseded = state { return false }
            throw CocoaError(.fileWriteUnknown)
        }
        guard matches else {
            try resolveMismatch(
                data, &removeTemporary, temporary: temporary, target: url
            )
            return false
        }
        return true
    }

    /// Compares a displaced or current file with the planned snapshot without
    /// reading more than its size or a special file: an external write can be
    /// arbitrarily large, and reading a FIFO would block the caller.
    private func snapshotMatches(at url: URL, expected: Data) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue == expected.count else {
            return false
        }
        return try Data(contentsOf: url) == expected
    }

    /// Restores the displaced bytes after a failed comparison. A failed
    /// exchange keeps the temporary file, which holds the only remaining copy
    /// of the external save, instead of deleting it.
    private func undoExchange(
        _ removeTemporary: inout Bool, temporary: URL, target: URL
    ) throws {
        guard renamex_np(temporary.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            removeTemporary = false
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private enum DestinationState {
        /// Still contains exactly the bytes this call published.
        case published
        /// A regular file with other bytes: a newer external save wins.
        case superseded
        /// Missing, special or unreadable: the displaced copy must be kept.
        case unknown
    }

    private func destinationState(published: Data, at url: URL) -> DestinationState {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return .unknown
        }
        guard (attributes[.size] as? NSNumber)?.intValue == published.count else {
            return .superseded
        }
        guard let current = try? Data(contentsOf: url) else { return .unknown }
        return current == published ? .published : .superseded
    }

    /// Rolls back only while the destination still holds this call's bytes.
    /// A regular newer save makes the displaced copy obsolete; for a missing,
    /// special or unreadable destination the displaced bytes are the only
    /// remaining copy, so they are kept and the write fails closed.
    @discardableResult
    private func resolveMismatch(
        _ published: Data, _ removeTemporary: inout Bool, temporary: URL, target: URL
    ) throws -> DestinationState {
        let state = destinationState(published: published, at: target)
        switch state {
        case .published:
            try undoExchange(&removeTemporary, temporary: temporary, target: target)
        case .superseded:
            break
        case .unknown:
            removeTemporary = false
            throw CocoaError(.fileWriteUnknown)
        }
        return state
    }

    /// Moves the destination aside atomically, then verifies what was moved.
    /// A plain compare-then-remove can delete a save another process made
    /// between the comparison and the removal.
    func removeData(at url: URL, expecting expected: Data) throws -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).lithe-\(UUID().uuidString)"
        )
        guard renamex_np(url.path, temporary.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == ENOENT { return false }
            if renameIsUnsupported() {
                return try removeAfterCompare(at: url, expected: expected)
            }
            throw CocoaError(.fileWriteUnknown)
        }
        var removeTemporary = true
        defer { if removeTemporary { try? FileManager.default.removeItem(at: temporary) } }

        let matches: Bool
        do {
            matches = try snapshotMatches(at: temporary, expected: expected)
        } catch {
            removeTemporary = restoreMovedFile(temporary, to: url)
            throw CocoaError(.fileWriteUnknown)
        }
        guard matches else {
            removeTemporary = restoreMovedFile(temporary, to: url)
            return false
        }
        return true
    }

    /// Puts a file moved aside by a failed conditional remove back. Returns
    /// whether the temporary copy may be deleted: a newer file that appeared at
    /// the destination wins, while other failures keep the moved bytes.
    private func restoreMovedFile(_ temporary: URL, to url: URL) -> Bool {
        if renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 {
            return true
        }
        // EEXIST: another process already created a newer file; keep that one.
        return errno == EEXIST
    }
    /// `renamex_np` flags are volume capabilities. Volumes without them still
    /// need working MCP saves, so fall back to compare-then-write/remove and
    /// accept the same residual window a plain atomic write had.
    private func renameIsUnsupported() -> Bool {
        errno == ENOTSUP || errno == EOPNOTSUPP || errno == EINVAL || errno == ENOSYS
    }

    private func publishNewFileWithoutExchange(_ data: Data, at url: URL) throws -> Bool {
        do {
            try data.write(to: url, options: .withoutOverwriting)
            return true
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return false
        } catch {
            // Exclusive create can leave a partial file on some failures.
            // Remove it only when it is a prefix of our own bytes, so a file
            // another process created meanwhile is never deleted.
            if let current = try? Data(contentsOf: url),
               current.count < data.count, data.starts(with: current) {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private func publishAfterCompare(
        _ data: Data, at url: URL, expecting expected: Data
    ) throws -> Bool {
        guard try snapshotMatches(at: url, expected: expected) else { return false }
        try data.write(to: url, options: .atomic)
        return true
    }

    private func removeAfterCompare(at url: URL, expected: Data) throws -> Bool {
        guard try snapshotMatches(at: url, expected: expected) else { return false }
        try FileManager.default.removeItem(at: url)
        return true
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }
}
