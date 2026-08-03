import Foundation

protocol ArchiveEntryReader: Sendable {
    func read(entry: String, from archive: URL) -> String?
}
