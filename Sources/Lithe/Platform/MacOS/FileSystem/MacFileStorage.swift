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

    func metadata(for url: URL) -> FileMetadata? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isRegularFileKey,
            .isDirectoryKey
        ]) else { return nil }
        return FileMetadata(
            byteCount: values.fileSize,
            modificationDate: values.contentModificationDate,
            isRegularFile: values.isRegularFile == true,
            isDirectory: values.isDirectory == true
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
}
