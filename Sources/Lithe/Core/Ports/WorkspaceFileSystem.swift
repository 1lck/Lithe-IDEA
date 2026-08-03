import Foundation

struct WorkspaceFileMetadata: Sendable {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isHidden: Bool
}

protocol WorkspaceFileSystem: Sendable {
    func metadata(for url: URL) -> WorkspaceFileMetadata
    func contentsOfDirectory(at url: URL) -> [URL]
}
