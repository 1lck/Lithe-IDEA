import LitheCoreContracts

typealias FileNode = LitheCoreContracts.FileNode
typealias WorkspaceSnapshot = LitheCoreContracts.WorkspaceSnapshot

extension FileNode {
    var iconKind: LitheIconKind {
        LitheIcons.kind(for: url, isDirectory: isDirectory, isInsideSourceRoot: isInsideSourceRoot)
    }
}
