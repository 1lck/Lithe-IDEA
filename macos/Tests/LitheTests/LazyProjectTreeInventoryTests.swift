import Foundation
import LitheCoreContracts
import LitheWorkspaceModule
import Testing

@Suite("Lazy project tree inventory")
@MainActor
struct LazyProjectTreeInventoryTests {
    @Test
    func directoryListingBeforeWatcherPreservesCreatedAndDeletedSignals() async throws {
        let root = URL(fileURLWithPath: "/in-memory/lazy-tree-inventory")
        let docs = root.appendingPathComponent("docs")
        let removed = docs.appendingPathComponent("Old.md")
        let created = docs.appendingPathComponent("New.md")
        let fixture = InventoryFixture(root: root, files: [removed], rows: [
            root.path: [FileNode(url: docs, isDirectory: true, children: nil)],
            docs.path: [FileNode(url: removed, isDirectory: false, children: nil)],
        ])
        defer { fixture.close() }
        await fixture.load()
        #expect(fixture.model.rootNode?.node(exactlyAt: docs)?.isUnloadedDirectory == true)

        // The listing observes the new disk revision before its watcher batch.
        fixture.disk.set(files: [created], rows: [
            root.path: [FileNode(url: docs, isDirectory: true, children: nil)],
            docs.path: [FileNode(url: created, isDirectory: false, children: nil)],
        ])
        await fixture.model.loadExpandedDirectories([root.path, docs.path])
        #expect(fixture.model.rootNode?.node(exactlyAt: created)?.url == created)
        #expect(fixture.model.rootNode?.node(exactlyAt: removed) == nil)
        #expect(fixture.model.projectFiles == [removed])
        #expect(fixture.model.appliedSnapshot?.files == [removed])

        let finished = fixture.expectRefresh(for: created)
        try fixture.emit([created, removed])
        #expect(await finished.waitUntilOpen(), "The watcher batch did not finish")
        #expect(fixture.changes == [
            WorkspaceFileChange(fileURL: created, kind: .created),
            WorkspaceFileChange(fileURL: removed, kind: .deleted),
        ])
        #expect(fixture.model.projectFiles == [created])
        #expect(fixture.model.appliedSnapshot?.files == [created])
        #expect(fixture.publishedFiles.last == [created])
        #expect(fixture.model.rootNode?.node(exactlyAt: created)?.url == created)
        #expect(fixture.model.rootNode?.node(exactlyAt: removed) == nil)
        #expect(fixture.disk.snapshotCount == 1)
    }

    @Test(arguments: [false, true])
    func compactPackageRelistingCannotOverwriteANewerRootFileChange(deletingB: Bool) async throws {
        let root = URL(fileURLWithPath: "/in-memory/lazy-tree-relisting")
        let source = root.appendingPathComponent("src")
        let package = source.appendingPathComponent("app")
        let main = package.appendingPathComponent("Main.java")
        let a = source.appendingPathComponent("A.java")
        let b = root.appendingPathComponent("B.md")
        let compact = FileNode(url: package, isDirectory: true, children: nil,
                               collapsedAncestorPaths: [source.path])
        let initialFiles = deletingB ? [main, b] : [main]
        let fixture = InventoryFixture(root: root, files: initialFiles, rows: [
            root.path: [compact] + (deletingB ? [FileNode(url: b, isDirectory: false, children: nil)] : []),
            package.path: [FileNode(url: main, isDirectory: false, children: nil)],
        ])
        defer { fixture.close() }
        await fixture.load()
        await fixture.model.loadExpandedDirectories([root.path, package.path])
        let initialSnapshotID = fixture.model.appliedSnapshot?.id
        let aFinished = fixture.expectRefresh(for: a)
        let bFinished = fixture.expectRefresh(for: b)

        let afterA = initialFiles + [a]
        let rootRowsAfterA = [FileNode(url: source, isDirectory: true, children: nil)]
            + (deletingB ? [FileNode(url: b, isDirectory: false, children: nil)] : [])
        fixture.disk.set(files: afterA, rows: [
            root.path: rootRowsAfterA,
            source.path: [FileNode(url: package, isDirectory: true, children: nil),
                          FileNode(url: a, isDirectory: false, children: nil)],
            package.path: [FileNode(url: main, isDirectory: false, children: nil)],
        ])
        fixture.disk.blockNextListing()
        try fixture.emit([a])
        #expect(await fixture.disk.listingStarted.waitUntilOpen(), "A did not reach the production listing worker")
        #expect(Set(fixture.model.projectFiles) == Set(afterA))
        #expect(Set(fixture.model.appliedSnapshot?.files ?? []) == Set(afterA))
        #expect(Set(fixture.publishedFiles.last ?? []) == Set(afterA))
        #expect(fixture.model.appliedSnapshot?.id != initialSnapshotID)

        // B commits while A's worker still owns an older directory listing.
        let finalFiles = deletingB ? [main, a] : [main, a, b]
        fixture.disk.set(files: finalFiles, rows: [
            root.path: [FileNode(url: source, isDirectory: true, children: nil)]
                + (deletingB ? [] : [FileNode(url: b, isDirectory: false, children: nil)]),
            source.path: [FileNode(url: package, isDirectory: true, children: nil),
                          FileNode(url: a, isDirectory: false, children: nil)],
            package.path: [FileNode(url: main, isDirectory: false, children: nil)],
        ])
        try fixture.emit([b])
        #expect(await bFinished.waitUntilOpen(), "B did not finish while A was blocked")
        #expect(Set(fixture.model.projectFiles) == Set(finalFiles))
        #expect(Set(fixture.model.appliedSnapshot?.files ?? []) == Set(finalFiles))
        let newerSnapshotID = fixture.model.appliedSnapshot?.id
        #expect(fixture.changes == [
            WorkspaceFileChange(fileURL: a, kind: .created),
            WorkspaceFileChange(fileURL: b, kind: deletingB ? .deleted : .created),
        ])

        fixture.disk.releaseListing.open()
        #expect(await aFinished.waitUntilOpen(), "A did not finish after its listing was released")
        #expect(!fixture.disk.listingTimedOut)
        #expect(Set(fixture.model.projectFiles) == Set(finalFiles))
        #expect(Set(fixture.model.appliedSnapshot?.files ?? []) == Set(finalFiles))
        #expect(fixture.model.appliedSnapshot?.id == newerSnapshotID)
        // The stale compact row must also be replaced, even though B cancelled
        // A's debounce task. Checking before expansion catches lost layout work.
        #expect(fixture.model.rootNode?.node(exactlyAt: source)?.url == source)
        #expect((fixture.model.rootNode?.node(exactlyAt: b) != nil) == !deletingB)
        await fixture.model.loadExpandedDirectories([root.path, source.path, package.path])
        #expect(fixture.model.rootNode?.node(exactlyAt: a)?.url == a)
        #expect(Set(fixture.model.rootNode?.fileURLs ?? []) == Set(finalFiles))
        #expect(fixture.disk.snapshotCount == 1)
    }
}

@MainActor
private final class InventoryFixture {
    let root: URL
    let disk: InventoryDisk
    let watcher = InventoryWatcherFactory()
    let model: WorkspaceFeatureModel
    var changes: [WorkspaceFileChange] = []
    var publishedFiles: [[URL]] = []
    private var refreshGates: [String: TestGate] = [:]

    init(root: URL, files: [URL], rows: [String: [FileNode]]) {
        self.root = root
        disk = InventoryDisk(files: files, rows: rows)
        model = WorkspaceFeatureModel(
            operations: disk, fileOperations: disk,
            gitWatchContextProvider: InventoryGitContext(), directoryWatcherFactory: watcher,
            workspaceSessionStore: InventorySessionStore(), observationDelay: { _ in }
        )
        model.configureProjection(
            documentsProvider: { [] }, activeDocumentProvider: { nil },
            selectedSidebarProvider: { "project" }, setSelectedSidebar: { _ in },
            restoreSession: { _, _ in }, openFile: { _ in }, notify: { _ in },
            recordHistory: { _, _ in }, relocateHistory: { _, _ in },
            relocateOpenDocuments: { _, _ in }, closeDocuments: { _ in },
            processExternalChanges: { _ in false },
            notifyWorkspaceFileChanges: { [weak self] in self?.changes.append(contentsOf: $0) },
            reloadProjectServices: {}, refreshGit: {}, updateHistoryVisibilityRules: { _ in },
            onSnapshotLoaded: { [weak self] snapshot, _ in self?.publishedFiles.append(snapshot.files) },
            warmSearchIndex: { _, _ in },
            updateSearchIndex: { [weak self] _, paths, _ in
                for path in paths { self?.refreshGates[path]?.open() }
            },
            invalidateSearchIndex: { _, _ in }
        )
    }

    func load() async {
        model.beginWorkspace(at: root, visibilityRules: .default)
        _ = await model.rebuild(at: root, rules: .default, isCurrent: { true })
    }

    func expectRefresh(for url: URL) -> TestGate {
        let gate = TestGate()
        refreshGates[url.path] = gate
        return gate
    }

    func emit(_ urls: [URL]) throws {
        let source = try #require(watcher.source)
        source.emit(urls.map(\.path))
    }

    func close() {
        disk.releaseListing.open()
        model.reset()
        refreshGates.values.forEach { $0.open() }
    }
}

/// Both protocols are synchronous; only WorkspaceFeatureModel's production
/// listing worker enters the bounded blocking gate, never the test's main actor.
private final class InventoryDisk: WorkspaceOperations, WorkspaceFileOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [URL]
    private var rows: [String: [FileNode]]
    private var shouldBlock = false
    private var timedOut = false
    private var scans = 0
    let listingStarted = TestGate()
    let releaseListing = TestGate()

    init(files: [URL], rows: [String: [FileNode]]) {
        self.files = files
        self.rows = rows
    }

    var snapshotCount: Int { lock.withLock { scans } }
    var listingTimedOut: Bool { lock.withLock { timedOut } }

    func set(files: [URL], rows: [String: [FileNode]]) {
        lock.withLock { self.files = files; self.rows = rows }
    }

    func blockNextListing() { lock.withLock { shouldBlock = true } }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        lock.withLock {
            scans += 1
            return WorkspaceSnapshot(root: FileNode(url: rootURL, isDirectory: true, children: nil), files: files)
        }
    }

    func childRows(of requested: [FileNode], at rootURL: URL,
                   visibilityRules: FileVisibilityRules) -> [String: [FileNode]]? {
        let (captured, blocks) = lock.withLock {
            let blocks = shouldBlock
            shouldBlock = false
            return (rows, blocks)
        }
        if blocks {
            listingStarted.open()
            // This synchronous protocol is invoked on the production listing worker.
            let released = releaseListing.waitSynchronously(timeout: 5)
            lock.withLock { timedOut = !released }
            guard released else { return nil }
        }
        return Dictionary(uniqueKeysWithValues: requested.map { ($0.url.path, captured[$0.url.path] ?? []) })
    }

    func fileExists(at url: URL) -> Bool { lock.withLock { files.contains(url.standardizedFileURL) } }
    func isDirectory(at url: URL) -> Bool { false }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
    func createFile(at url: URL) throws { throw CocoaError(.featureUnsupported) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { throw CocoaError(.featureUnsupported) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { throw CocoaError(.featureUnsupported) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { throw CocoaError(.featureUnsupported) }
    func removeItem(at url: URL) throws { throw CocoaError(.featureUnsupported) }
    func trashItem(at url: URL) throws { throw CocoaError(.featureUnsupported) }
    func writeText(_ text: String, to url: URL) throws { throw CocoaError(.featureUnsupported) }
    func readText(from url: URL) throws -> String { throw CocoaError(.featureUnsupported) }
}

private struct InventoryGitContext: GitWatchContextProviding {
    func watchContext(for workspace: URL) async -> GitWatchContext? { nil }
}

@MainActor
private final class InventorySessionStore: WorkspaceSessionStoring {
    func load(for workspaceURL: URL) -> WorkspaceSession? { nil }
    func save(_ session: WorkspaceSession, for workspaceURL: URL) {}
}

private final class InventoryWatcherFactory: DirectoryWatcherFactory {
    private(set) var source: InventoryChangeSource?
    func make(configuration: DirectoryWatchConfiguration, visibilityRules: FileVisibilityRules,
              onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) -> any DirectoryChangeSource {
        let source = InventoryChangeSource(onChange: onChange)
        self.source = source
        return source
    }
}

private final class InventoryChangeSource: DirectoryChangeSource {
    private let onChange: @Sendable (DirectoryChangeBatch) -> Void
    init(onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) { self.onChange = onChange }
    func start() {}
    func stop() {}
    func emit(_ paths: [String]) { onChange(DirectoryChangeBatch(workspacePaths: paths)) }
}
