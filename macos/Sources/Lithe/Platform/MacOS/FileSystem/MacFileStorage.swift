import Foundation

struct MacFileStorage: FileStorage {
    func homeDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    func cacheDirectory() -> URL {
        FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }

    func applicationSupportDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
    }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
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
