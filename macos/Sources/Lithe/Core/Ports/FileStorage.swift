import Foundation

struct FileMetadata: Sendable {
    let byteCount: Int?
    let modificationDate: Date?
    let isRegularFile: Bool
    let isDirectory: Bool
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
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func removeItem(at url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws
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
