import Foundation

struct RecentProject: Codable, Identifiable, Hashable, Sendable {
    let path: String
    var lastOpened: Date
    /// Branch recorded when the project was last opened; `nil` for folders
    /// that were not a repository. Stored with the list so the welcome screen
    /// can show it without loading Git.
    var branch: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
}
