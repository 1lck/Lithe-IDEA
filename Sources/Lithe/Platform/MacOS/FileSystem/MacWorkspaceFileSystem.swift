import Foundation

struct MacWorkspaceFileSystem: WorkspaceFileSystem {
    func metadata(for url: URL) -> WorkspaceFileMetadata {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isHiddenKey
        ])
        return WorkspaceFileMetadata(
            isDirectory: values?.isDirectory == true,
            isSymbolicLink: values?.isSymbolicLink == true,
            isHidden: values?.isHidden == true
        )
    }

    func contentsOfDirectory(at url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
            options: []
        )) ?? []
    }
}
