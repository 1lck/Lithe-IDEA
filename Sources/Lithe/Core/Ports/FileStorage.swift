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
}
