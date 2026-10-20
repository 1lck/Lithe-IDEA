import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project tree compaction lookahead")
struct ProjectTreeLoaderTests {
    @Test
    func singleDirectoryChainIsCompleteInItsFirstPublishedListing() throws {
        let root = URL(fileURLWithPath: "/fixture/infra")
        let docker = root.appendingPathComponent("docker")
        let database = docker.appendingPathComponent("database-validation")
        let sibling = database.appendingPathComponent("scripts")
        let file = database.appendingPathComponent("compose.yaml")
        let disk: [String: [ProjectDirectoryEntry]] = [
            root.path: [.init(url: docker, isDirectory: true)],
            docker.path: [.init(url: database, isDirectory: true)],
            database.path: [.init(url: sibling, isDirectory: true), .init(url: file, isDirectory: false)],
        ]
        var reads: [String] = []
        let loader = ProjectTreeLoader { urls in
            reads += urls.map(\.path)
            return Dictionary(uniqueKeysWithValues: urls.compactMap { url in disk[url.path].map { (url.path, $0) } })
        }
        let unloaded = FileNode(url: root, isDirectory: true, children: nil)
        let children = try #require(loader.childRows(of: [unloaded])?[root.path])
        let tree = FileNode(url: root, isDirectory: true, children: children)
        let expanded = ProjectTreeSelection.expandingSingleDirectoryChains(from: [root.path], in: tree, expandedPaths: [root.path])
        #expect(ProjectTreeSelection.visibleRows(in: tree, expandedPaths: expanded).map(\.node.name)
                == ["infra", "docker", "database-validation", "scripts", "compose.yaml"])
        #expect(reads == [root.path, docker.path, database.path])
        // Sibling subtrees remain unloaded, even though the sole-directory chain is ready at once.
        #expect(tree.node(exactlyAt: sibling)?.isUnloadedDirectory == true)
    }

    @Test
    func failedSingleDirectoryChainDoesNotReturnIntermediateRows() {
        let root = URL(fileURLWithPath: "/fixture/infra")
        let child = root.appendingPathComponent("docker")
        let loader = ProjectTreeLoader { urls in
            urls == [root] ? [root.path: [.init(url: child, isDirectory: true)]] : nil
        }
        #expect(loader.childRows(of: [FileNode(url: root, isDirectory: true, children: nil)]) == nil)
    }

    @Test
    func automaticChainLookaheadStopsAtItsDepthBound() throws {
        let root = URL(fileURLWithPath: "/fixture/chain")
        var reads = 0
        let loader = ProjectTreeLoader { urls in
            reads += urls.count
            return Dictionary(uniqueKeysWithValues: urls.map { url in
                (url.path, [ProjectDirectoryEntry(url: url.appendingPathComponent("next"), isDirectory: true)])
            })
        }
        let children = try #require(loader.childRows(of: [FileNode(url: root, isDirectory: true, children: nil)])?[root.path])
        #expect(reads == 65)
        var tip = try #require(children.first)
        for _ in 0..<64 { tip = try #require(tip.children?.first) }
        #expect(tip.isUnloadedDirectory)
    }

    @Test
    func emptyDirectoryHintsSurviveListingAndFallbackFiltering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("hidden-only"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("hidden-only/ignored.tmp"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parent/empty"), withIntermediateDirectories: true)
        let rules = FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: ["*.tmp"])
        let builder = FileSystemWorkspaceSnapshotBuilder()
        let loader = ProjectTreeLoader { builder.listDirectories($0, at: root, visibilityRules: rules) }
        let rows = try #require(loader.childRows(of: [FileNode(url: root, isDirectory: true, children: nil)])?[root.path])
        #expect(rows.first { $0.name == "logs" }?.children?.isEmpty == true)
        #expect(rows.first { $0.name == "hidden-only" }?.children?.isEmpty == true)
        #expect(rows.first { $0.name == "parent" }?.isUnloadedDirectory == true)
    }

    @Test
    func expandingCompactedPackageReusesItsListing() throws {
        let root = URL(fileURLWithPath: "/in-memory/lookahead")
        let source = root.appendingPathComponent("src/main/java")
        let com = source.appendingPathComponent("com")
        let package = com.appendingPathComponent("example")
        let file = package.appendingPathComponent("Main.java")
        let cache = ProjectDirectoryListingCache()
        let generation = cache.prepare(at: root, rules: .default)
        let disk: [String: [ProjectDirectoryEntry]] = [
            source.path: [.init(url: com, isDirectory: true)],
            com.path: [.init(url: package, isDirectory: true)],
            package.path: [.init(url: file, isDirectory: false)],
        ]
        var reads: [String: Int] = [:]
        let loader = ProjectTreeLoader(cache: cache, generation: generation) { directories in
            Dictionary(uniqueKeysWithValues: directories.map { directory in
                reads[directory.path, default: 0] += 1
                return (directory.path, disk[directory.path] ?? [])
            })
        }

        let first = try #require(loader.childRows(of: [FileNode(url: source, isDirectory: true, children: nil)]))
        let rows = try #require(first[source.path])
        #expect(rows.count == 1)
        #expect(rows.first?.url == package)
        #expect(rows.first?.collapsedAncestorPaths == [com.path])
        #expect(rows.first?.children?.map(\.url) == [file])
        #expect(reads == [source.path: 1, com.path: 1, package.path: 1])
        // Auto-expansion consumes compaction lookahead without a second read.
        // A later explicit refresh still reads the directory again.
        _ = loader.childRows(of: rows)
        #expect(reads[package.path] == 2)
    }

    @Test(arguments: ["event", "workspace", "rules"])
    func invalidationRejectsOldLookaheadAndLateWrites(reason: String) {
        let root = URL(fileURLWithPath: "/in-memory/lookahead")
        let cache = ProjectDirectoryListingCache()
        let old = cache.prepare(at: root, rules: .default)
        cache.store([], at: "pkg", generation: old)
        let current: UUID
        switch reason {
        case "workspace":
            current = cache.prepare(at: root.appendingPathComponent("other"), rules: .default)
        case "rules":
            current = cache.prepare(at: root, rules: FileVisibilityRules(hiddenDirectoryNames: ["excluded"], hiddenFilePatterns: []))
        default:
            cache.invalidate()
            current = cache.prepare(at: root, rules: .default)
        }
        #expect(current != old)
        #expect(cache.take("pkg", generation: current) == nil)
        cache.store([], at: "pkg", generation: old)
        #expect(cache.take("pkg", generation: current) == nil)
    }

    @Test
    func lookaheadHasEntryAndDirectoryBounds() {
        let root = URL(fileURLWithPath: "/in-memory/lookahead")
        let cache = ProjectDirectoryListingCache()
        let generation = cache.prepare(at: root, rules: .default)
        let large = (0..<4_097).map { ProjectDirectoryEntry(url: root.appendingPathComponent("F\($0)"), isDirectory: false) }
        cache.store(large, at: "large", generation: generation)
        #expect(cache.take("large", generation: generation) == nil)
        for index in 0..<129 { cache.store([], at: "D\(index)", generation: generation) }
        #expect(cache.take("D0", generation: generation) == nil)
        #expect(cache.take("D128", generation: generation)?.isEmpty == true)
    }

    @Test
    func failedCompactionListingDoesNotPublishPartialRows() {
        let source = URL(fileURLWithPath: "/in-memory/lookahead/src/main/java")
        let loader = ProjectTreeLoader { directories in
            directories == [source] ? [source.path: [.init(url: source.appendingPathComponent("com"), isDirectory: true)]] : nil
        }
        #expect(loader.childRows(of: [FileNode(url: source, isDirectory: true, children: nil)]) == nil)
    }
}
