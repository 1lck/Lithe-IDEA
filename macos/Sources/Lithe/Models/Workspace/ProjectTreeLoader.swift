import Foundation

/// One visible child returned by a directory listing.
struct ProjectDirectoryEntry: Sendable {
    let url: URL
    let isDirectory: Bool
    var isEmptyDirectory = false
}

/// Bounded, consumable lookahead from package compaction, never a second tree.
/// All access is locked; directory I/O always happens outside the lock.
final class ProjectDirectoryListingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var rootPath: String?
    private var rules: FileVisibilityRules?
    private var listings: [String: [ProjectDirectoryEntry]] = [:]
    private var entryCount = 0
    private static let maximumEntries = 4_096
    private static let maximumDirectories = 128

    func prepare(at root: URL, rules: FileVisibilityRules) -> UUID {
        lock.withLock {
            let path = root.standardizedFileURL.path
            if rootPath != path || self.rules != rules {
                invalidateLocked()
                rootPath = path
                self.rules = rules
            }
            return generation
        }
    }

    func invalidate() {
        lock.withLock { invalidateLocked() }
    }

    private func invalidateLocked() {
        generation = UUID()
        listings.removeAll()
        entryCount = 0
    }

    func take(_ path: String, generation: UUID) -> [ProjectDirectoryEntry]? {
        lock.withLock {
            guard self.generation == generation,
                  let entries = listings.removeValue(forKey: path) else { return nil }
            entryCount -= entries.count
            return entries
        }
    }

    func store(_ entries: [ProjectDirectoryEntry], at path: String, generation: UUID) {
        lock.withLock {
            guard self.generation == generation, entries.count <= Self.maximumEntries else { return }
            entryCount -= listings.removeValue(forKey: path)?.count ?? 0
            if entryCount + entries.count > Self.maximumEntries || listings.count >= Self.maximumDirectories {
                // ponytail: drop bounded lookahead wholesale on overflow; use LRU only if profiling shows churn.
                listings.removeAll()
                entryCount = 0
            }
            listings[path] = entries
            entryCount += entries.count
        }
    }
}

/// Builds one visible level plus its automatically expanded single-directory chain.
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
    private let cache: ProjectDirectoryListingCache?
    private let generation: UUID?

    init(
        cache: ProjectDirectoryListingCache? = nil,
        generation: UUID? = nil,
        list: @escaping ([URL]) -> [String: [ProjectDirectoryEntry]]?
    ) {
        self.cache = cache
        self.generation = generation
        self.list = list
    }

    private static let maximumCompactionDepth = 64

    func childRows(of rows: [FileNode]) -> [String: [FileNode]]? {
        guard var result = listedChildRows(of: rows) else { return nil }
        for row in rows {
            let key = row.url.standardizedFileURL.path
            guard var children = result[key] else { continue }
            var chain: [FileNode] = []
            // Only follow the one branch the UI will auto-expand, never sibling subtrees.
            for _ in 0..<Self.maximumCompactionDepth {
                guard !Task.isCancelled else { return nil }
                guard children.count == 1, let child = children.first,
                      child.isDirectory, child.children?.isEmpty != true,
                      !child.url.lastPathComponent.hasPrefix(".") else { break }
                guard let listed = listedChildRows(of: [child]), !Task.isCancelled else { return nil }
                // An omitted probe is unreadable or gone, not a failure of its readable parent.
                guard let next = listed[child.url.standardizedFileURL.path] else { break }
                chain.append(child)
                children = next
            }
            for directory in chain.reversed() {
                children = [FileNode(
                    url: directory.url, isDirectory: true, children: children,
                    collapsedAncestorPaths: directory.collapsedAncestorPaths,
                    isInsideSourceRoot: directory.isInsideSourceRoot
                )]
            }
            result[key] = children
        }
        return result
    }

    private func listedChildRows(of rows: [FileNode]) -> [String: [FileNode]]? {
        guard !Task.isCancelled, let listings = cachedList(rows.map(\.url)) else { return nil }
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
                    children: entry.isEmptyDirectory ? [] : nil,
                    isInsideSourceRoot: entry.isDirectory && insideSourceRoot
                )
            }
        }

        for _ in 0..<Self.maximumCompactionDepth where !chains.isEmpty {
            guard !Task.isCancelled else { return nil }
            guard let listed = cachedList(chains.map(\.tip)) else { return nil }
            var continuing: [CompactionChain] = []
            for var chain in chains {
                guard let entries = listed[chain.tip.standardizedFileURL.path] else {
                    chain.apply(to: &result)
                    continue
                }
                if entries.count == 1, let only = entries.first, only.isDirectory,
                   LitheIcons.isValidPackageName(only.url.lastPathComponent) {
                    chain.collapsed.append(chain.tip.path)
                    chain.tip = only.url
                    continuing.append(chain)
                } else {
                    if let entries = listed[chain.tip.standardizedFileURL.path], let generation {
                        cache?.store(entries, at: chain.tip.standardizedFileURL.path, generation: generation)
                    }
                    chain.apply(to: &result, isEmpty: entries.isEmpty)
                }
            }
            chains = continuing
        }
        chains.forEach { $0.apply(to: &result) }
        return result
    }

    private func cachedList(_ directories: [URL]) -> [String: [ProjectDirectoryEntry]]? {
        var result: [String: [ProjectDirectoryEntry]] = [:]
        var missing: [URL] = []
        for directory in directories {
            let path = directory.standardizedFileURL.path
            if let generation, let entries = cache?.take(path, generation: generation) {
                result[path] = entries
            } else {
                missing.append(directory)
            }
        }
        if !missing.isEmpty {
            guard let listed = list(missing) else { return nil }
            result.merge(listed) { _, new in new }
        }
        return result
    }

    /// A child directory being followed through single-subdirectory packages.
    private struct CompactionChain {
        let owner: String
        let index: Int
        var tip: URL
        var collapsed: [String] = []

        func apply(to result: inout [String: [FileNode]], isEmpty: Bool = false) {
            guard !collapsed.isEmpty else { return }
            result[owner]?[index] = FileNode(
                url: tip,
                isDirectory: true,
                children: isEmpty ? [] : nil,
                collapsedAncestorPaths: collapsed,
                isInsideSourceRoot: true
            )
        }
    }
}
