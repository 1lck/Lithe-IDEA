import Combine
import Foundation
import LitheCoreContracts
import LitheWorkspaceModule
import Testing

@Suite("Lazy project tree inventory")
@MainActor
struct LazyProjectTreeInventoryTests {
    @Test
    func moduleReleaseDuringSnapshotCannotAcquireAnotherLeaseOrPublishInventory() async {
        let root = URL(fileURLWithPath: "/in-memory/indexing-release-during-snapshot")
        let fixture = InventoryFixture(root: root, files: [], rows: [root.path: []])
        defer { fixture.close() }
        fixture.disk.setConfigurationRevision(10)
        fixture.disk.blockNextListing()
        fixture.model.beginWorkspace(at: root, visibilityRules: .default)
        let loading = Task { await fixture.model.rebuild(at: root, rules: .default, isCurrent: { true }) }
        defer { loading.cancel(); fixture.disk.releaseListing.open() }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        fixture.model.prepareForModuleRelease()
        #expect(await fixture.disk.releaseObserved.waitUntilOpen())
        fixture.disk.releaseListing.open()
        let result = await loading.value
        if case .stale = result {} else { Issue.record("A released workspace published its inventory") }
        #expect(fixture.disk.configurationCount == 1)
        #expect(fixture.disk.releasedRoots == [root])
        #expect(fixture.publishedFiles.isEmpty)
    }

    @Test
    func aCompleteIndexingRescanPublishesRecoveryEvenWhenTheFileListIsUnchanged() async {
        let root = URL(fileURLWithPath: "/in-memory/indexing-complete-recovery")
        let file = root.appendingPathComponent("Keep.java")
        let fixture = InventoryFixture(root: root, files: [file], rows: [root.path: []])
        defer { fixture.close() }
        fixture.disk.setIncompleteDirectories(["unreadable"])
        await fixture.load()
        #expect(fixture.publishedFiles.isEmpty)
        #expect(fixture.model.appliedSnapshot?.incompleteDirectories == ["unreadable"])
        fixture.disk.setIncompleteDirectories([])
        _ = await fixture.model.rebuild(at: root, rules: .default, refreshGitAfterwards: false, indexingOnly: true, isCurrent: { true })
        #expect(fixture.publishedFiles == [[file]])
        #expect(fixture.model.appliedSnapshot?.incompleteDirectories.isEmpty == true)
    }

    @Test
    func initialIndexingFailureKeepsProjectIdentityForRetryAndRefreshFailureKeepsTheTree() async {
        let root = URL(fileURLWithPath: "/in-memory/indexing-retry"); let file = root.appendingPathComponent("Keep.java")
        let fixture = InventoryFixture(root: root, files: [file], rows: [root.path: []])
        defer { fixture.close() }
        fixture.disk.failNextConfiguration(.workspaceUnavailable)
        await fixture.load()
        #expect(fixture.model.loadErrorMessage != nil)
        #expect(!fixture.model.isLoadingWorkspace)
        #expect(fixture.model.rootNode == nil)
        await fixture.model.refreshCurrent()
        #expect(fixture.model.projectFiles == [file])
        #expect(fixture.model.loadErrorMessage == nil)
        fixture.disk.failNextConfiguration(.configureFailed)
        await fixture.model.refreshCurrent()
        #expect(fixture.model.projectFiles == [file])
        #expect(fixture.model.rootNode != nil)
        #expect(fixture.model.loadErrorMessage == nil)
        #expect(fixture.model.indexingError != nil)
        #expect(!fixture.model.isRefreshingWorkspace)
    }

    @Test
    func normalFolderDoesNotCreateAnIncludeExceptionButCancelExclusionDoes() async {
        let root = URL(fileURLWithPath: "/in-memory/indexing-normal-folder")
        let directory = root.appendingPathComponent("src")
        let fixture = InventoryFixture(root: root, files: [directory.appendingPathComponent("Keep.java")], rows: [root.path: []])
        defer { fixture.close() }
        await fixture.load()
        await fixture.model.markDirectory(directory, as: .sources)
        await fixture.model.markDirectory(directory, as: .plain)
        #expect(fixture.model.indexingSettings.includedDirectories.isEmpty)
        #expect(fixture.model.directoryMarks["src"] == .plain)
        await fixture.model.markDirectory(directory, as: .excluded)
        await fixture.model.markDirectory(directory, as: .plain, cancelExclusion: true)
        #expect(fixture.model.indexingSettings.includedDirectories == ["src"])
        #expect(fixture.model.directoryMarks["src"] == .plain)
    }

    @Test(arguments: [false, true], [false, true])
    func stalePolicyInstallCannotOverwriteOrFailTheNextWorkspace(staleFails: Bool, reopenSameRoot: Bool) async {
        let oldRoot = URL(fileURLWithPath: "/in-memory/old-indexing")
        let nextRoot = reopenSameRoot ? oldRoot : URL(fileURLWithPath: "/in-memory/next-indexing")
        let file = nextRoot.appendingPathComponent("Keep.java")
        let fixture = InventoryFixture(root: nextRoot, files: [file], rows: [nextRoot.path: []])
        defer { fixture.close() }
        fixture.disk.blockNextConfiguration(failing: staleFails)
        fixture.model.beginWorkspace(at: oldRoot, visibilityRules: .default)
        let oldGeneration = fixture.model.workspaceGeneration
        let first = Task { await fixture.model.rebuild(at: oldRoot, rules: .default,
            isCurrent: { fixture.model.workspaceGeneration == oldGeneration }) }
        defer { first.cancel(); fixture.disk.releaseConfiguration.open() }
        #expect(await fixture.disk.configurationStarted.waitUntilOpen())
        fixture.model.beginWorkspace(at: nextRoot, visibilityRules: .default)
        let nextGeneration = fixture.model.workspaceGeneration
        fixture.disk.blockNextListing()
        let second = Task { await fixture.model.rebuild(at: nextRoot, rules: .default,
            isCurrent: { fixture.model.workspaceGeneration == nextGeneration }) }
        defer { second.cancel(); fixture.disk.releaseListing.open() }
        fixture.disk.releaseConfiguration.open()
        let obsolete = await first.value
        if case .stale = obsolete {} else { Issue.record("Old configuration was published") }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        #expect(fixture.model.isLoadingWorkspace)
        #expect(fixture.model.indexingError == nil)
        #expect(fixture.disk.releasedRoots == (staleFails ? [] : [oldRoot]))
        fixture.disk.releaseListing.open()
        _ = await second.value
        #expect(fixture.model.projectFiles == [file])
        #expect(!fixture.model.isLoadingWorkspace)
        #expect(!fixture.disk.configurationTimedOut)
    }

    @Test
    func visibilityRefreshCannotPublishAcrossSameRootReopen() async {
        let root = URL(fileURLWithPath: "/in-memory/visibility-indexing-reopen")
        let file = root.appendingPathComponent("Keep.java")
        let fixture = InventoryFixture(root: root, files: [file], rows: [root.path: []])
        defer { fixture.close() }
        await fixture.load()
        fixture.disk.blockNextConfiguration(failing: false)
        fixture.model.updateVisibilityRules(FileVisibilityRules(hiddenDirectoryNames: ["old-hidden"], hiddenFilePatterns: []))
        #expect(await fixture.disk.configurationStarted.waitUntilOpen())
        fixture.model.reset()
        fixture.model.beginWorkspace(at: root, visibilityRules: .default)
        let generation = fixture.model.workspaceGeneration
        fixture.disk.blockNextListing()
        let reopened = Task { await fixture.model.rebuild(at: root, rules: .default,
            isCurrent: { fixture.model.workspaceGeneration == generation }) }
        defer { reopened.cancel(); fixture.disk.releaseListing.open(); fixture.disk.releaseConfiguration.open() }
        fixture.disk.releaseConfiguration.open()
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        #expect(fixture.disk.releasedRoots == [root])
        #expect(fixture.model.isLoadingWorkspace)
        fixture.disk.releaseListing.open()
        _ = await reopened.value
        #expect(fixture.model.projectFiles == [file])
        #expect(fixture.model.indexingError == nil)
        #expect(!fixture.disk.configurationTimedOut)
    }

    @Test(arguments: [false, true])
    func policyInstalledAfterProjectCloseIsReleased(moduleRelease: Bool) async {
        let root = URL(fileURLWithPath: "/in-memory/closed-indexing")
        let fixture = InventoryFixture(root: root, files: [], rows: [root.path: []])
        defer { fixture.close() }
        fixture.disk.blockNextConfiguration(failing: false)
        fixture.model.beginWorkspace(at: root, visibilityRules: .default)
        let generation = fixture.model.workspaceGeneration
        let loading = Task { await fixture.model.rebuild(at: root, rules: .default,
            isCurrent: { fixture.model.workspaceGeneration == generation }) }
        defer { loading.cancel(); fixture.disk.releaseConfiguration.open() }
        #expect(await fixture.disk.configurationStarted.waitUntilOpen())
        if moduleRelease { fixture.model.prepareForModuleRelease() } else { fixture.model.reset() }
        fixture.disk.releaseConfiguration.open()
        _ = await loading.value
        #expect(fixture.disk.releasedRoots == [root])
        #expect(fixture.model.rootNode == nil)
        #expect(!fixture.disk.configurationTimedOut)
    }

    @Test
    func unsupportedWorkspaceRejectsExclusionActions() async {
        let root = URL(fileURLWithPath: "/in-memory/unsupported-indexing")
        let file = root.appendingPathComponent("src/Keep.java")
        let fixture = InventoryFixture(root: root, files: [file], rows: [root.path: []])
        defer { fixture.close() }
        fixture.disk.supportsExclusions = false
        await fixture.load()
        await fixture.model.setGitIgnoreIndexing(false)
        await fixture.model.markDirectory(root.appendingPathComponent("src"), as: .excluded)
        #expect(fixture.model.indexingSettings.gitIgnoreEnabled)
        #expect(fixture.model.directoryMarks.isEmpty)
        #expect(fixture.model.projectFiles == [file])
        #expect(fixture.disk.snapshotCount == 1)
    }

    @Test(arguments: [false, true])
    func policyChangesDuringScanPublishOnlyTheLatestInventory(manualMark: Bool) async {
        let root = URL(fileURLWithPath: "/in-memory/indexing-policy-race")
        let directory = root.appendingPathComponent(manualMark ? "manual" : "ignored")
        let file = directory.appendingPathComponent("Candidate.java")
        let fixture = InventoryFixture(root: root, files: [file], rows: [
            root.path: [FileNode(url: directory, isDirectory: true, children: nil)], directory.path: [],
        ])
        defer { fixture.close() }
        fixture.disk.blockNextListing()
        let loading = Task { await fixture.load() }
        defer { loading.cancel(); fixture.disk.releaseListing.open() }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        if manualMark {
            await fixture.model.markDirectory(directory, as: .excluded)
        } else {
            await fixture.model.setGitIgnoreIndexing(false)
        }
        fixture.disk.releaseListing.open()
        await loading.value
        #expect(!fixture.disk.listingTimedOut)
        #expect(fixture.disk.snapshotCount == 2)
        #expect(fixture.model.projectFiles == (manualMark ? [] : [file]))
        #expect(fixture.publishedFiles == [manualMark ? [] : [file]])
        #expect(fixture.model.isIndexExcluded(directory) == manualMark)
        #expect(fixture.disk.appliedPolicy?.gitIgnoreEnabled == manualMark)
        #expect(fixture.disk.appliedPolicy?.manualExcludedDirectories == (manualMark ? ["manual"] : []))
    }

    @Test
    func expandAllLoadsEveryBranchWithoutRebuildingTheFileInventory() async throws {
        let root = URL(fileURLWithPath: "/in-memory/expand-all")
        let compactedAncestor = root.appendingPathComponent("first")
        let first = compactedAncestor.appendingPathComponent("compacted")
        let second = root.appendingPathComponent("second")
        let nested = first.appendingPathComponent("nested")
        let file = nested.appendingPathComponent("Guide.md")
        let fixture = InventoryFixture(root: root, files: [file], rows: [
            root.path: [
                FileNode(url: first, isDirectory: true, children: nil, collapsedAncestorPaths: [compactedAncestor.path]),
                FileNode(url: second, isDirectory: true, children: nil),
            ],
            first.path: [FileNode(url: nested, isDirectory: true, children: nil)],
            second.path: [], nested.path: [FileNode(url: file, isDirectory: false, children: nil)],
        ])
        defer { fixture.close() }
        await fixture.load()
        let scans = fixture.disk.snapshotCount
        let paths = try #require(await fixture.model.loadAllDirectories())
        #expect(paths == [root.path, compactedAncestor.path, first.path, second.path, nested.path])
        #expect(fixture.model.rootNode?.unloadedRows(expandedPaths: paths).isEmpty == true)
        #expect(fixture.model.projectFiles == [file])
        #expect(fixture.disk.snapshotCount == scans)
        #expect(fixture.disk.listingCount(for: first) == 1)
        #expect(fixture.disk.listingCount(for: second) == 1)
        #expect(fixture.disk.listingCount(for: nested) == 1)
    }

    @Test(arguments: [false, true])
    func cancelledOrResetExpandAllCannotReturnExpansionState(reset: Bool) async {
        let root = URL(fileURLWithPath: "/in-memory/expand-all-cancel")
        let child = root.appendingPathComponent("child")
        let fixture = InventoryFixture(root: root, files: [], rows: [
            root.path: [FileNode(url: child, isDirectory: true, children: nil)], child.path: [],
        ])
        defer { fixture.close() }
        await fixture.load()
        fixture.disk.blockNextListing()
        let expansion = Task { await fixture.model.loadAllDirectories() }
        defer { expansion.cancel(); fixture.disk.releaseListing.open() }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        if reset { fixture.model.reset() } else { expansion.cancel() }
        fixture.disk.releaseListing.open()
        #expect(await expansion.value == nil)
        #expect(!fixture.disk.listingTimedOut)
    }

    @Test
    func slowDirectoryDoesNotDelayPublishingAnotherExpansion() async {
        let root = URL(fileURLWithPath: "/in-memory/independent-expansions")
        let slow = root.appendingPathComponent("slow")
        let fast = root.appendingPathComponent("fast")
        let file = fast.appendingPathComponent("Guide.md")
        let fixture = InventoryFixture(root: root, files: [file], rows: [
            root.path: [slow, fast].map { FileNode(url: $0, isDirectory: true, children: nil) },
            slow.path: [],
            fast.path: [FileNode(url: file, isDirectory: false, children: nil)],
        ])
        defer { fixture.close() }
        await fixture.load()
        fixture.disk.blockNextListing()
        let first = Task { await fixture.model.loadExpandedDirectories([root.path, slow.path]) }
        defer { first.cancel(); fixture.disk.releaseListing.open() }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        let publishedFast = TestGate()
        let observation = fixture.model.$rootNode.sink { tree in
            if tree?.node(exactlyAt: file) != nil { publishedFast.open() }
        }
        defer { observation.cancel() }
        let second = Task { await fixture.model.loadExpandedDirectories([root.path, slow.path, fast.path]) }
        defer { second.cancel() }
        #expect(await publishedFast.waitUntilOpen(), "Fast directory waited for the blocked sibling")
        #expect(fixture.model.rootNode?.node(exactlyAt: slow)?.isUnloadedDirectory == true)
        fixture.disk.releaseListing.open()
        await first.value
        await second.value
        #expect(!fixture.disk.listingTimedOut)
        #expect(fixture.disk.listingCount(for: slow) == 1)
        #expect(fixture.disk.listingCount(for: fast) == 1)
    }

    @Test
    func resettingWorkspaceRejectsInflightExpansion() async {
        let root = URL(fileURLWithPath: "/in-memory/reset-expansion")
        let docs = root.appendingPathComponent("docs")
        let fixture = InventoryFixture(root: root, files: [], rows: [
            root.path: [FileNode(url: docs, isDirectory: true, children: nil)],
            docs.path: [],
        ])
        defer { fixture.close() }
        await fixture.load()
        fixture.disk.blockNextListing()
        let expansion = Task { await fixture.model.loadExpandedDirectories([root.path, docs.path]) }
        defer { expansion.cancel(); fixture.disk.releaseListing.open() }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        fixture.model.reset()
        fixture.disk.releaseListing.open()
        await expansion.value
        #expect(!fixture.disk.listingTimedOut)
        #expect(fixture.model.rootNode == nil)
        #expect(fixture.model.projectFiles.isEmpty)
    }

    @Test(arguments: [false, true])
    func overlappingExpansionsShareListingEvenWhenOneCallerCancels(cancelFirst: Bool) async {
        let root = URL(fileURLWithPath: "/in-memory/shared-expansion")
        let docs = root.appendingPathComponent("docs")
        let file = docs.appendingPathComponent("Guide.md")
        let fixture = InventoryFixture(root: root, files: [file], rows: [
            root.path: [FileNode(url: docs, isDirectory: true, children: nil)],
            docs.path: [FileNode(url: file, isDirectory: false, children: nil)],
        ])
        defer { fixture.close() }
        await fixture.load()
        fixture.disk.blockNextListing()
        let first = Task { await fixture.model.loadExpandedDirectories([root.path, docs.path]) }
        defer { first.cancel(); fixture.disk.releaseListing.open() }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        let secondStarted = TestGate()
        let second = Task {
            secondStarted.open()
            await fixture.model.loadExpandedDirectories([root.path, docs.path])
        }
        defer { second.cancel() }
        #expect(await secondStarted.waitUntilOpen())
        if cancelFirst { first.cancel() }
        fixture.disk.releaseListing.open()
        await first.value
        await second.value
        #expect(!fixture.disk.listingTimedOut)
        #expect(fixture.disk.listingCount(for: docs) == 1)
        #expect(fixture.model.rootNode?.node(exactlyAt: file)?.url == file)
    }

    @Test
    func watcherEventDiscardsInflightListingAndRetriesCurrentDirectory() async throws {
        let root = URL(fileURLWithPath: "/in-memory/stale-expansion")
        let docs = root.appendingPathComponent("docs")
        let old = docs.appendingPathComponent("Old.md")
        let added = docs.appendingPathComponent("New.md")
        let fixture = InventoryFixture(root: root, files: [old], rows: [
            root.path: [FileNode(url: docs, isDirectory: true, children: nil)],
            docs.path: [FileNode(url: old, isDirectory: false, children: nil)],
        ])
        defer { fixture.close() }
        await fixture.load()
        fixture.disk.blockNextListing()
        let expansion = Task { await fixture.model.loadExpandedDirectories([root.path, docs.path]) }
        defer { expansion.cancel(); fixture.disk.releaseListing.open() }
        #expect(await fixture.disk.listingStarted.waitUntilOpen())
        fixture.disk.set(files: [old, added], rows: [
            root.path: [FileNode(url: docs, isDirectory: true, children: nil)],
            docs.path: [old, added].map { FileNode(url: $0, isDirectory: false, children: nil) },
        ])
        let refreshed = fixture.expectRefresh(for: added)
        try fixture.emit([added])
        #expect(await refreshed.waitUntilOpen())
        fixture.disk.releaseListing.open()
        await expansion.value
        #expect(!fixture.disk.listingTimedOut)
        #expect(fixture.disk.listingCount(for: docs) == 2)
        #expect(Set(fixture.model.rootNode?.node(exactlyAt: docs)?.fileURLs ?? []) == Set([old, added]))
    }

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
        disk.releaseConfiguration.open()
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
    private var incompleteDirectories: [String] = []
    func setIncompleteDirectories(_ paths: [String]) { lock.withLock { incompleteDirectories = paths } }
    private var policy: WorkspaceIndexingPolicy?
    var supportsExclusions = true
    private var blockConfiguration = false
    private var failConfiguration = false
    private var configurationTimeout = false
    private var configurationRevision: UInt64 = 0
    private var configurations = 0
    var configurationCount: Int { lock.withLock { configurations } }
    func setConfigurationRevision(_ revision: UInt64) { lock.withLock { configurationRevision = revision } }
    let releaseObserved = TestGate()
    private var nextFailure: WorkspaceIndexingFailure?
    func failNextConfiguration(_ error: WorkspaceIndexingFailure) { lock.withLock { nextFailure = error } }
    private var releases: [URL] = []
    let configurationStarted = TestGate()
    let releaseConfiguration = TestGate()
    var releasedRoots: [URL] { lock.withLock { releases } }
    var configurationTimedOut: Bool { lock.withLock { configurationTimeout } }
    func blockNextConfiguration(failing: Bool) { lock.withLock { blockConfiguration = true; failConfiguration = failing } }
    func releaseIndexing(at rootURL: URL, revision: UInt64, ownerID: String? = nil) { lock.withLock { releases.append(rootURL) }; releaseObserved.open() }
    private var listings: [String: Int] = [:]
    let listingStarted = TestGate()
    let releaseListing = TestGate()

    init(files: [URL], rows: [String: [FileNode]]) {
        self.files = files
        self.rows = rows
    }

    var appliedPolicy: WorkspaceIndexingPolicy? { lock.withLock { policy } }
    var snapshotCount: Int { lock.withLock { scans } }
    var listingTimedOut: Bool { lock.withLock { timedOut } }
    func listingCount(for url: URL) -> Int { lock.withLock { listings[url.path, default: 0] } }

    func set(files: [URL], rows: [String: [FileNode]]) {
        lock.withLock { self.files = files; self.rows = rows }
    }

    func blockNextListing() { lock.withLock { shouldBlock = true } }

    func configureIndexing(at rootURL: URL, policy: WorkspaceIndexingPolicy, refresh: Bool, ownerID: String? = nil) throws -> WorkspaceIndexingStatus {
        lock.withLock { configurations += 1 }
        if let error = lock.withLock({ let error = nextFailure; nextFailure = nil; return error }) { throw error }
        let (blocks, fails) = lock.withLock {
            let blocks = blockConfiguration
            blockConfiguration = false
            return (blocks, failConfiguration)
        }
        if blocks {
            configurationStarted.open()
            // Only the production synchronous configuration worker enters this bounded gate.
            let released = releaseConfiguration.waitSynchronously(timeout: 5)
            lock.withLock { configurationTimeout = !released }
            if !released || fails { throw CocoaError(.fileReadUnknown) }
        }
        return lock.withLock {
            self.policy = policy
            var status = WorkspaceIndexingStatus()
            status.supportsExclusions = supportsExclusions
            status.revision = blocks ? 1 : configurationRevision
            status.excludedDirectories = Dictionary(uniqueKeysWithValues: policy.manualExcludedDirectories.map { ($0, "manual") })
            if policy.gitIgnoreEnabled { status.excludedDirectories["ignored"] = "git" }
            return status
        }
    }

    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? {
        lock.withLock {
            scans += 1
            let visible = files.filter { file in
                let relative = String(file.path.dropFirst(rootURL.path.count + 1))
                return !(policy?.manualExcludedDirectories.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) ?? false)
                    && !(policy?.gitIgnoreEnabled == true && relative.hasPrefix("ignored/"))
            }
            return WorkspaceSnapshot(root: FileNode(url: rootURL, isDirectory: true, children: nil), files: visible, incompleteDirectories: incompleteDirectories)
        }
    }

    func childRows(of requested: [FileNode], at rootURL: URL,
                   visibilityRules: FileVisibilityRules) -> [String: [FileNode]]? {
        let (captured, blocks) = lock.withLock {
            for row in requested { listings[row.url.path, default: 0] += 1 }
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
