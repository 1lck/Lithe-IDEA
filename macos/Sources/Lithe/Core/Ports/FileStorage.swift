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
    /// leaves the destination unchanged when another writer got there first.
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func removeItem(at url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
}

extension FileStorage {
    /// Fallback for storages without a native compare-and-publish operation.
    /// Production uses the platform implementation; this version performs the
    /// final comparison as late as the port allows.
    func replaceData(_ data: Data, at url: URL, expecting expected: Data?) throws -> Bool {
        guard let expected else {
            guard !fileExists(at: url) else { return false }
            try writeData(data, to: url, options: .withoutOverwriting)
            return true
        }
        guard fileExists(at: url) else { return false }
        let current: Data
        do {
            current = try readData(from: url, options: [])
        } catch {
            return false
        }
        guard current == expected else { return false }
        try writeData(data, to: url, options: .atomic)
        return true
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
