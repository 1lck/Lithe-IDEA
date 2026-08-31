import Foundation

package struct FileNode: Identifiable, Hashable, Sendable {
    package let url: URL
    package let isDirectory: Bool
    package let children: [FileNode]?
    /// 被压缩的中间包所对应的目录（不含本节点自身）。展开/折叠时需要
    /// 一并处理，否则父目录的展开状态会和显示的行对不上。
    package let collapsedAncestorPaths: [String]
    /// 该目录是否位于源码根之下，决定用包图标还是普通文件夹图标。
    package let isInsideSourceRoot: Bool

    package init(
        url: URL,
        isDirectory: Bool,
        children: [FileNode]?,
        collapsedAncestorPaths: [String] = [],
        isInsideSourceRoot: Bool = false
    ) {
        self.url = url
        self.isDirectory = isDirectory
        self.children = children
        self.collapsedAncestorPaths = collapsedAncestorPaths
        self.isInsideSourceRoot = isInsideSourceRoot
    }

    package var id: String { url.path }

    /// 压缩中间包后显示的名字，例如 com.alibaba.nacos.ai。
    package var name: String {
        guard !collapsedAncestorPaths.isEmpty else { return url.lastPathComponent }
        let names = collapsedAncestorPaths.map { ($0 as NSString).lastPathComponent }
        return (names + [url.lastPathComponent]).joined(separator: ".")
    }

}

package struct WorkspaceSnapshot: Sendable {
    package let root: FileNode
    package let files: [URL]
    /// Distinguishes this scan of the workspace from any other.
    ///
    /// Consumers that scan `files` compare this identity to decide whether their
    /// inventory is current. Carrying it in the snapshot is what keeps a file
    /// list from ever being paired with a different scan's identity.
    package let id: UUID

    package init(root: FileNode, files: [URL], id: UUID = UUID()) {
        self.root = root
        self.files = files
        self.id = id
    }
}
