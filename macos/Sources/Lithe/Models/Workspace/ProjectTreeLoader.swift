import Foundation

/// One visible child returned by a directory listing.
struct ProjectDirectoryEntry: Sendable {
    let url: URL
    let isDirectory: Bool
}

/// Builds project tree rows one directory level at a time.
///
/// The tree used to be built from a scan of the whole workspace, so every file
/// cost a node before anything was shown (issue #1245). Rows now start
/// unloaded and are listed when expanded. Compact Middle Packages still need
/// to look ahead: a package row absorbs each directory below it that holds
/// only one subdirectory, so the loader lists those chains until they end.
struct ProjectTreeLoader {
    /// Lists the given directories, keyed by standardized path. Directories
    /// that no longer exist are left out; nil means listing is unavailable.
    let list: ([URL]) -> [String: [ProjectDirectoryEntry]]?

    private static let maximumCompactionDepth = 64

    func childRows(of rows: [FileNode]) -> [String: [FileNode]]? {
        guard let listings = list(rows.map(\.url)) else { return nil }
        var result: [String: [FileNode]] = [:]
        var chains: [CompactionChain] = []
        for row in rows {
            let key = row.url.standardizedFileURL.path
            guard let entries = listings[key] else { continue }
            // Same rule as the full-tree conversion: below a source root,
            // directories are packages and single-child chains compact.
            let insideSourceRoot = row.isInsideSourceRoot || LitheIcons.isSourceRootDirectory(row.url)
            result[key] = entries.enumerated().map { index, entry in
                if entry.isDirectory, insideSourceRoot {
                    chains.append(CompactionChain(owner: key, index: index, tip: entry.url))
                }
                return FileNode(
                    url: entry.url,
                    isDirectory: entry.isDirectory,
                    children: nil,
                    isInsideSourceRoot: entry.isDirectory && insideSourceRoot
                )
            }
        }

        for _ in 0..<Self.maximumCompactionDepth where !chains.isEmpty {
            guard let listed = list(chains.map(\.tip)) else { break }
            var continuing: [CompactionChain] = []
            for var chain in chains {
                let entries = listed[chain.tip.standardizedFileURL.path] ?? []
                if entries.count == 1, let only = entries.first, only.isDirectory,
                   LitheIcons.isValidPackageName(only.url.lastPathComponent) {
                    chain.collapsed.append(chain.tip.path)
                    chain.tip = only.url
                    continuing.append(chain)
                } else {
                    chain.apply(to: &result)
                }
            }
            chains = continuing
        }
        chains.forEach { $0.apply(to: &result) }
        return result
    }

    /// A child directory being followed through single-subdirectory packages.
    private struct CompactionChain {
        let owner: String
        let index: Int
        var tip: URL
        var collapsed: [String] = []

        func apply(to result: inout [String: [FileNode]]) {
            guard !collapsed.isEmpty else { return }
            result[owner]?[index] = FileNode(
                url: tip,
                isDirectory: true,
                children: nil,
                collapsedAncestorPaths: collapsed,
                isInsideSourceRoot: true
            )
        }
    }
}
