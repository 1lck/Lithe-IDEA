import Foundation

struct RecentProject: Codable, Identifiable, Hashable, Sendable {
    let path: String
    var lastOpened: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}
