import Foundation

struct FileMetadata: Sendable {
    let byteCount: Int?
    let modificationDate: Date?
    let isRegularFile: Bool
    let isDirectory: Bool
    let isWritable: Bool

    init(
        byteCount: Int?, modificationDate: Date?, isRegularFile: Bool,
        isDirectory: Bool, isWritable: Bool = true
    ) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.isWritable = isWritable
    }
}

/// A conditional write could not be completed and the displaced bytes were
/// kept beside the destination instead of being deleted.
struct FileStorageRetainedCopyError: LocalizedError, Equatable, Sendable {
    let destinationPath: String
    let retainedPath: String

    var errorDescription: String? {
        String(
            format: String(localized: "Could not write %@. The previous contents were kept in %@."),
            destinationPath,
            retainedPath
        )
    }
}

protocol FileStorage: Sendable {
    func homeDirectory() -> URL
    func cacheDirectory() -> URL
    func applicationSupportDirectory() -> URL
    func temporaryDirectory() -> URL
    func metadata(for url: URL) -> FileMetadata?
    func fileExists(at url: URL) -> Bool
    func isExecutable(at url: URL) -> Bool
    func listDirectory(at url: URL) -> [URL]
    /// Reads at most `byteCount` bytes for bounded format probing.
    func readPrefix(from url: URL, byteCount: Int) throws -> Data
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    /// Publishes `data` only while the destination still matches `expected`
    /// (or does not exist when `expected` is `nil`). Returns `false` and
    /// restores the previous bytes when another writer got there first; a
    /// failed rollback keeps them in a hidden temporary file next to `url`.
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool
    /// Removes `url` only while it still matches `expected`. Returns `false`
    /// and leaves the file in place when another writer changed it.
    func removeData(at url: URL, expecting expected: Data) throws -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func removeItem(at url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
}

extension FileStorage {
    /// Every platform storage must provide a real compare-and-publish
    /// operation. A generic fallback would silently weaken the lost-update
    /// guarantee on a future adapter, so the port fails closed instead.
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        throw CocoaError(.featureUnsupported)
    }

    /// Same for conditional removal: never degrade to compare-then-remove.
    func removeData(at url: URL, expecting expected: Data) throws -> Bool {
        throw CocoaError(.featureUnsupported)
    }
}

struct UnavailableFileStorage: FileStorage {
    private let root = URL(fileURLWithPath: "/unavailable")
    func homeDirectory() -> URL { root }
    func cacheDirectory() -> URL { root }
    func applicationSupportDirectory() -> URL { root }
    func temporaryDirectory() -> URL { root }
    func metadata(for url: URL) -> FileMetadata? { nil }
    func fileExists(at url: URL) -> Bool { false }
    func isExecutable(at url: URL) -> Bool { false }
    func listDirectory(at url: URL) -> [URL] { [] }
    func readPrefix(from url: URL, byteCount: Int) throws -> Data { throw CocoaError(.fileReadNoSuchFile) }
    func readData(from url: URL, options: Data.ReadingOptions) throws -> Data { throw CocoaError(.fileReadNoSuchFile) }
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws { throw CocoaError(.fileWriteNoPermission) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { throw CocoaError(.fileWriteNoPermission) }
    func removeItem(at url: URL) throws { throw CocoaError(.fileNoSuchFile) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { throw CocoaError(.fileNoSuchFile) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { throw CocoaError(.fileNoSuchFile) }
}
