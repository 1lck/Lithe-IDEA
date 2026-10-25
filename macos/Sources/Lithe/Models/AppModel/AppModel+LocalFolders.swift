import Foundation

/// One row of the Open panel's folder list.
struct FolderListingEntry: Identifiable, Equatable {
    let name: String
    let isDirectory: Bool
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
            .map { FolderListingEntry(name: $0.lastPathComponent, isDirectory: storage.metadata(for: $0)?.isDirectory == true) }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }
}
