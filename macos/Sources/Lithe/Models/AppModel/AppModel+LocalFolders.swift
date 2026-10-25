import Foundation

/// One row of the Open panel's folder list.
struct FolderListingEntry: Identifiable, Equatable {
    let name: String
    let isDirectory: Bool
    /// Bytes of a file; `nil` for folders and when unknown.
    var byteCount: Int64?
    var modified: Date?
    var id: String { name }
}

@MainActor
extension AppModel {
    /// The home folder, where the Open panel starts browsing this Mac.
    var localHomeFolderPath: String { services.fileStorage.homeDirectory().path }

    /// The visible entries of a local folder, folders first; `nil` when `path`
    /// is not a readable folder.
    func localFolderEntries(at path: String) -> [FolderListingEntry]? {
        let storage = services.fileStorage
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard storage.metadata(for: url)?.isDirectory == true else { return nil }
        return storage.listDirectory(at: url)
            .map { url in
                let metadata = storage.metadata(for: url)
                let isDirectory = metadata?.isDirectory == true
                return FolderListingEntry(
                    name: url.lastPathComponent, isDirectory: isDirectory,
                    byteCount: isDirectory ? nil : metadata?.byteCount.map(Int64.init),
                    modified: metadata?.modificationDate
                )
            }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }
}
