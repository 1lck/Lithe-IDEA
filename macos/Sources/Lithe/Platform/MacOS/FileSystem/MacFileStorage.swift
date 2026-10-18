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
        defer { try? FileManager.default.removeItem(at: temporary) }

        if expected == nil {
            // Publish without replacing a file another process just created.
            guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { return false }
                throw CocoaError(.fileWriteUnknown)
            }
            return true
        }

        // The exchange also returns the previous contents: reading them from
        // `temporary` is how a lost external save becomes observable.
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            guard try Data(contentsOf: temporary) == expected else {
                _ = renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP))
                return false
            }
        } catch {
            _ = renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP))
            throw error
        }
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
