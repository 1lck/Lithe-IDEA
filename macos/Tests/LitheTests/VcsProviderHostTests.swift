import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
@testable import Lithe

/// The macOS host side of plugin VCS providers: the feature model against
/// a fake Core and fake provider processes, the real Core adapter, the
/// install review, and the tool window's pure presentation rules.
@Suite("VCS provider host")
@MainActor
struct VcsProviderHostTests {
    // MARK: Feature model

    @Test
    func detectsPluginRootsReadsStatusAndColorsOnlyTheFilesTheRootOwns() async throws {
        // A Git repository nested in the working copy takes part in
        // ownership but is not listed; its directory is the Git root's.
        let fixture = try VcsFeatureFixture(roots: [("", "svn"), ("vendor/lib", "git")])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([
            ("a.txt", "modified"), ("build", "unversioned"), ("vendor/lib", "unversioned"), ("debug.log", "ignored")
        ])

        #expect(await fixture.open())
        #expect(fixture.feature.roots.map(\.id) == [""])
        #expect(fixture.feature.roots.first?.title == "workspace")
        #expect(fixture.feature.roots.first?.snapshot?.head.revision?.display == "r7")
        #expect(fixture.feature.vcsNames == ["svn": "Subversion", "git": "Git"])
        let feature = fixture.feature
        let modifiedURL = fixture.url("a.txt")
        let colored = await awaitChange(on: feature) { feature.treeStatus.status(for: modifiedURL) == .modified }
        #expect(colored)
        let tree = feature.treeStatus
        // Rows below an unversioned directory share its status.
        #expect(tree.status(for: fixture.url("build/classes/Main.class")) == .unversioned)
        #expect(tree.status(for: fixture.url("vendor/lib")) == nil)
        #expect(tree.status(for: fixture.url("vendor/lib/x.c")) == nil)
        #expect(tree.status(for: fixture.url("debug.log")) == nil)
        #expect(fixture.providers.requests == [.init(operation: .status(includeIgnored: false), root: fixture.workspaceURL.path)])
        #expect(fixture.providers.retainCount > 0)
    }

    @Test
    func refreshesOnlyForWorkingFilesAndDeclaredMetadataOutsideHostActions() async throws {
        let fixture = try VcsFeatureFixture(roots: [("", "svn"), ("module", "svn")])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([])
        let workspace = fixture.workspaceURL.path
        let module = fixture.url("module").path
        #expect(await fixture.open())
        #expect(fixture.providers.statusCount(root: workspace) == 1)
        #expect(fixture.providers.statusCount(root: module) == 1)
        fixture.clock.advance(by: .seconds(3))

        // Metadata the provider did not declare never refreshes; a working
        // file does. Both arrive before the delay, so one refresh covers them.
        fixture.metadataWatchers.deliver([fixture.url(".svn/tmp/x")])
        fixture.changed("module/File.java")
        #expect(await fixture.settled { fixture.providers.statusCount(root: module) == 2 })
        #expect(fixture.providers.statusCount(root: workspace) == 1)

        // The host's own action writes metadata; those events are ignored
        // for a short while, working files still count.
        #expect(await fixture.feature.cleanup("module"))
        #expect(await fixture.settled { fixture.providers.statusCount(root: module) == 3 })
        fixture.metadataWatchers.deliver([fixture.url(".svn/wc.db")])
        fixture.changed("module/Other.java")
        #expect(await fixture.settled { fixture.providers.statusCount(root: module) == 4 })
        #expect(fixture.providers.statusCount(root: workspace) == 1)

        // Once the quiet period ends, the declared metadata path refreshes
        // its root, as an update from the command line would.
        fixture.clock.advance(by: .seconds(3))
        fixture.metadataWatchers.deliver([fixture.url(".svn/wc.db")])
        #expect(await fixture.settled { fixture.providers.statusCount(root: workspace) == 2 })
        #expect(fixture.providers.statusCount(root: module) == 4)
    }

    /// The workspace watcher hides VCS metadata as the project tree does,
    /// and never sees `../.svn` of a working copy that encloses the
    /// workspace, so every root's metadata directory is watched on its own.
    @Test
    func watchesTheMetadataDirectoryOfEveryRoot() async throws {
        let fixture = try VcsFeatureFixture(
            workspaceURL: URL(fileURLWithPath: "/virtual/wc/app", isDirectory: true),
            roots: [("..", "svn"), ("lib", "svn")]
        )
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([])
        let enclosing = fixture.workspaceURL.appendingPathComponent("..").path
        let lib = fixture.url("lib").path
        let metadata = URL(fileURLWithPath: "/virtual/wc/.svn", isDirectory: true)
        #expect(await fixture.open())
        #expect(fixture.metadataWatchers.running == [metadata.path, fixture.url("lib/.svn").path])
        #expect(fixture.providers.statusCount(root: enclosing) == 1)
        fixture.clock.advance(by: .seconds(3))

        fixture.metadataWatchers.deliver([metadata.appendingPathComponent("wc.db")])
        #expect(await fixture.settled { fixture.providers.statusCount(root: enclosing) == 2 })
        #expect(fixture.providers.statusCount(root: lib) == 1)
        fixture.metadataWatchers.deliver([fixture.url("lib/.svn/wc.db")])
        #expect(await fixture.settled { fixture.providers.statusCount(root: lib) == 2 })
        #expect(fixture.providers.statusCount(root: enclosing) == 2)

        // A watch that lost its events detects the roots again.
        fixture.clock.advance(by: .seconds(3))
        fixture.metadataWatchers.deliver(DirectoryChangeBatch(requiresFullRescan: true))
        #expect(await fixture.settled { fixture.planner.detectCount == 2 })
        #expect(fixture.metadataWatchers.running == [metadata.path, fixture.url("lib/.svn").path])

        fixture.close()
        #expect(fixture.metadataWatchers.running.isEmpty)
    }

    /// The workspace watcher hides `.svn`, so a working copy checked out in
    /// the workspace shows only as created entries beside its marker.
    @Test
    func detectsAWorkingCopyThatAppearsInTheWorkspace() async throws {
        let fixture = try VcsFeatureFixture(roots: [("", "svn")])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([])
        fixture.files.add(fixture.url(".svn"), fixture.url("plugins/.svn"))
        #expect(await fixture.open())
        fixture.clock.advance(by: .seconds(3))

        // A created entry and the directory holding it are looked up unless
        // they are a known root; a changed file is not looked up at all.
        let lookedUp = fixture.files.gate(afterLookups: 3)
        fixture.changed("plugins/Plugin.java")
        fixture.created("README.md", "src/Main.java")
        #expect(await lookedUp.waitUntilOpen(timeout: .seconds(5)))
        #expect(Set(fixture.files.lookups)
            == Set(["README.md/.svn", "src/Main.java/.svn", "src/.svn"].map { fixture.url($0).path }))

        fixture.created("plugins/Plugin.java")
        #expect(await fixture.settled { fixture.planner.detectCount == 2 })
        #expect(!fixture.files.lookups.contains(fixture.url(".svn").path))
    }

    @Test
    func runsOneWorkingCopyActionAtATime() async throws {
        let fixture = try VcsFeatureFixture(roots: [("", "svn")])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([("a.txt", "modified")])
        fixture.providers.replies["checkin"] = try VcsTestData.json(["revision": ["id": "8", "display": "r8", "kind": "number"]])
        #expect(await fixture.open())
        let checkinHeld = TestGate()
        fixture.providers.holds["checkin"] = checkinHeld
        defer { checkinHeld.open() }

        let feature = fixture.feature
        let commit = Task { await feature.checkin(["a.txt"], message: "Fix", in: "") }
        #expect(await awaitChange(on: feature) { feature.runningOperation?.rootID == "" })
        #expect(await feature.rollback(["a.txt"], in: "") == false)
        #expect(feature.failure?.message == String(localized: "Wait for the running version control action to finish."))

        checkinHeld.open()
        #expect(await commit.value?.revision?.display == "r8")
        #expect(feature.runningOperation == nil)
        #expect(fixture.providers.requests.map(\.operation.name).filter { $0 != "status" } == ["checkin"])
        #expect(fixture.providers.requests.contains(
            .init(operation: .checkin(paths: ["a.txt"], message: "Fix"), root: fixture.workspaceURL.path)
        ))
    }

    @Test
    func movesTrackedItemsThroughTheProviderAndLeavesTheRestToTheDisk() async throws {
        let fixture = try VcsFeatureFixture(
            roots: [("", "svn"), ("module", "svn"), ("lib", "git")], ambiguous: ["mixed"]
        )
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([
            ("a.txt", "modified"), ("new.txt", "unversioned"), ("out", "unversioned")
        ])
        #expect(await fixture.open())
        let feature = fixture.feature
        #expect(await awaitChange(on: feature) { feature.treeStatus.status(for: fixture.url("new.txt")) != nil })

        #expect(await feature.move(from: fixture.url("a.txt"), to: fixture.url("docs/a.txt")))
        #expect(fixture.providers.requests.contains(
            .init(operation: .move(from: "a.txt", to: "docs/a.txt"), root: fixture.workspaceURL.path)
        ))
        // The VCS does not track an unversioned item, cannot move into an
        // unversioned directory, and cannot move between working copies.
        #expect(await feature.move(from: fixture.url("new.txt"), to: fixture.url("docs/new.txt")) == false)
        #expect(await feature.move(from: fixture.url("b.txt"), to: fixture.url("out/b.txt")) == false)
        #expect(await feature.move(from: fixture.url("b.txt"), to: fixture.url("module/b.txt")) == false)
        // A nested Git repository and a directory with no VCS chosen are not
        // the working copy's, on either end of the move.
        #expect(await feature.move(from: fixture.url("b.txt"), to: fixture.url("lib/b.txt")) == false)
        #expect(await feature.move(from: fixture.url("lib/c.txt"), to: fixture.url("c.txt")) == false)
        #expect(await feature.move(from: fixture.url("b.txt"), to: fixture.url("mixed/b.txt")) == false)
        #expect(await feature.move(from: fixture.url("mixed/c.txt"), to: fixture.url("c.txt")) == false)
        #expect(fixture.providers.requests.filter { $0.operation.name == "fileOperation" }.count == 1)

        // A refusal is reported; the caller then moves the item on disk.
        fixture.providers.failures["fileOperation"] = VcsProviderFailure(code: "vcs.provider.failed", message: "E155010")
        #expect(await feature.move(from: fixture.url("b.txt"), to: fixture.url("c.txt")) == false)
        #expect(feature.failure?.message == "E155010")
    }

    /// An action that starts while a move asks Core who owns its paths
    /// leaves the move to the disk, as one running before would, instead of
    /// reporting the move as refused.
    @Test
    func moveYieldsToAnActionThatStartsWhileOwnershipIsChecked() async throws {
        let fixture = try VcsFeatureFixture(roots: [("", "svn")])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([("a.txt", "modified")])
        fixture.providers.replies["checkin"] = try VcsTestData.json(["revision": ["id": "8", "display": "r8", "kind": "number"]])
        #expect(await fixture.open())
        let ownersEntered = TestGate()
        let ownersReleased = TestGate()
        let checkinHeld = TestGate()
        fixture.planner.heldOwners = (paths: ["b.txt"], entered: ownersEntered, released: ownersReleased)
        fixture.providers.holds["checkin"] = checkinHeld
        defer {
            ownersReleased.open()
            checkinHeld.open()
        }

        let feature = fixture.feature
        let source = fixture.url("b.txt")
        let destination = fixture.url("docs/b.txt")
        let move = Task { await feature.move(from: source, to: destination) }
        #expect(await ownersEntered.waitUntilOpen(timeout: .seconds(5)))
        let commit = Task { await feature.checkin(["a.txt"], message: "Fix", in: "") }
        #expect(await awaitChange(on: feature) { feature.runningOperation?.rootID == "" })
        ownersReleased.open()

        #expect(await move.value == false)
        #expect(feature.failure == nil)
        checkinHeld.open()
        #expect(await commit.value?.revision?.display == "r8")
        #expect(!fixture.providers.requests.contains { $0.operation.name == "fileOperation" })
        #expect(!fixture.planner.ownersTimedOut)
    }

    @Test
    func remembersTheChosenVcsPerWorkspaceAndForgetsChoicesNoLongerNeeded() async throws {
        let fixture = try VcsFeatureFixture(roots: [("", "svn")], ambiguous: ["mixed"])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([])
        #expect(await fixture.open())
        #expect(fixture.feature.ambiguous.map(\.id) == ["mixed"])
        let store = MacVcsRootMappingStore(store: fixture.keyValues)
        let choice = VcsRootMapping(id: "mixed", vcs: "svn")

        fixture.feature.map("mixed", to: "svn")
        #expect(await fixture.settled { fixture.planner.detectCount == 2 })
        #expect(fixture.planner.lastMappings == [choice])
        #expect(store.mappings(workspaceURL: fixture.workspaceURL) == [choice])
        #expect(store.mappings(workspaceURL: fixture.url("other")).isEmpty)

        // Core reports the choice unused once the directory is no longer
        // ambiguous, and the host drops it.
        fixture.planner.detection = try VcsTestData.detection(
            roots: [("", "svn")], workspaceURL: fixture.workspaceURL, unusedMappings: [choice]
        )
        fixture.feature.detect()
        #expect(await fixture.settled { fixture.planner.detectCount == 3 })
        #expect(store.mappings(workspaceURL: fixture.workspaceURL).isEmpty)
        #expect(fixture.keyValues.isEmpty)
    }

    @Test
    func mappingStoreKeepsChoicesSortedPerWorkspace() {
        let keyValues = VcsTestKeyValueStore()
        let store = MacVcsRootMappingStore(store: keyValues)
        let workspace = URL(fileURLWithPath: "/virtual/a")
        let mappings = [VcsRootMapping(id: "z", vcs: "svn"), VcsRootMapping(id: "a", vcs: "git")]

        store.setMappings(mappings, workspaceURL: workspace)
        #expect(store.mappings(workspaceURL: workspace) == mappings.reversed())
        #expect(store.mappings(workspaceURL: URL(fileURLWithPath: "/virtual/b")).isEmpty)
        store.setMappings([], workspaceURL: workspace)
        #expect(keyValues.isEmpty)
    }

    @Test
    func providerFailuresLeadWithTheHintTheContractNames() {
        let outOfDate = VcsProviderFailure(code: "vcs.outOfDate", message: "E160024: out of date")
        #expect(VcsProvidersFeatureModel.message(for: outOfDate)
            == String(localized: "The working copy is out of date. Update it, then commit again.") + "\nE160024: out of date")
        #expect(VcsProvidersFeatureModel.message(for: VcsProviderFailure(code: "vcs.workingCopy.locked", message: ""))
            == String(localized: "The working copy is locked by an interrupted action. Run Cleanup, then try again."))
        #expect(VcsProvidersFeatureModel.message(for: VcsProviderFailure(code: "vcs.provider.failed", message: "boom"))
            == "boom")
    }

    @Test
    func rootPathsMapToTheWorkspaceEvenFromAnEnclosingWorkingCopy() {
        let workspace = URL(fileURLWithPath: "/virtual/wc/app/web")
        #expect(VcsProvidersFeatureModel.workspacePath("a.txt", rootID: "", workspaceURL: workspace) == "a.txt")
        #expect(VcsProvidersFeatureModel.workspacePath("a.txt", rootID: "lib", workspaceURL: workspace) == "lib/a.txt")
        // The workspace opened two levels inside the working copy.
        #expect(VcsProvidersFeatureModel.workspacePath("app/web/src/a.txt", rootID: "../..", workspaceURL: workspace)
            == "src/a.txt")
        #expect(VcsProvidersFeatureModel.workspacePath("app/web", rootID: "../..", workspaceURL: workspace) == "")
        #expect(VcsProvidersFeatureModel.workspacePath("app/webapp/a.txt", rootID: "../..", workspaceURL: workspace) == nil)
        #expect(VcsProvidersFeatureModel.workspacePath("README", rootID: "../..", workspaceURL: workspace) == nil)
    }

    // MARK: Tool window rules

    @Test
    func changeListPutsConflictsFirstAndIncludesOnlyVersionedChangesByDefault() throws {
        let changes = [
            VcsChange(path: "z.txt", status: .modified),
            VcsChange(path: "new.txt", status: .unversioned),
            VcsChange(path: "b.txt", status: .modified, flags: ["treeConflict"]),
            VcsChange(path: "a.txt", status: .conflicted),
            VcsChange(path: "c.txt", status: .added),
            VcsChange(path: "debug.log", status: .ignored)
        ]
        let groups = VcsProviderToolWindowView.groups(changes)

        #expect(groups.map(\.group) == [.conflicts, .changes, .unversioned])
        #expect(groups.map { $0.changes.map(\.path) } == [["a.txt", "b.txt"], ["c.txt", "z.txt"], ["new.txt"]])
        #expect(changes.filter(VcsProviderToolWindowView.isIncludedByDefault).map(\.path) == ["z.txt", "c.txt"])
    }

    /// A provider declares no icon; its window and command show the host's
    /// version control icon, not the generic tool window one.
    @Test
    func providerWindowsShowTheVersionControlIcon() {
        let contributions = DeclarativeVcsProvider(id: "svn", displayName: "Subversion")
            .contributions(pluginID: VcsTestData.pluginID, order: 0)
        #expect(contributions.map(\.uiIcon) == [PluginUIIcon(host: "git"), PluginUIIcon(host: "git")])
        let asset = WorkbenchContributionIcon.Asset(contributions[0].uiIcon, resources: nil)
        #expect(asset.hostPath == "expui/toolwindows/vcs@20x20.svg")
    }

    @Test
    func commitCarriesBothHalvesOfAMoveOnce() {
        let paths = VcsProviderToolWindowView.commitPaths([
            VcsChange(path: "src/New.java", oldPath: "src/Old.java", status: .renamed),
            VcsChange(path: "src/Old.java", status: .deleted),
            VcsChange(path: "README", status: .modified)
        ])
        #expect(paths == ["src/New.java", "src/Old.java", "README"])
    }

    @Test
    func headAndHistoryDatesReadAsTheProviderSentThem() throws {
        let head = try JSONDecoder().decode(VcsHead.self, from: Data(
            #"{"revision":{"id":"7","display":"r7","kind":"number"},"branch":"trunk","location":null}"#.utf8
        ))
        #expect(VcsProviderToolWindowView.headSummary(head) == "r7 · trunk")

        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-22T08:30:00Z"))
        let expected = date.formatted(date: .abbreviated, time: .shortened)
        #expect(VcsHistoryListView.displayDate("2026-10-22T08:30:00Z") == expected)
        #expect(VcsHistoryListView.displayDate("2026-10-22T08:30:00.250Z") == expected)
        #expect(VcsHistoryListView.displayDate("yesterday") == "yesterday")
    }

    // MARK: Rust Core and install review

    @Test
    func rustCoreDetectsAPluginRootBesideNestedGitAndValidatesReplies() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-vcs-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".svn"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("vendor/lib/.git"), withIntermediateDirectories: true
        )
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: VcsTestData.svnProviderManifest())
        let planner = RustVcsOperations(core: RustCoreBridge())

        let detection = try planner.detectRoots(
            workspaceURL: workspace, manifests: [descriptor.normalizedManifest], mappings: []
        )
        #expect(Set(detection.roots.map { "\($0.vcs):\($0.id)" }) == ["svn:", "git:vendor/lib"])
        let svn = try #require(detection.providers.first { $0.vcs == "svn" })
        #expect(svn.origin.pluginID == descriptor.id.rawValue)
        #expect(svn.metadataPaths == [".svn/wc.db"])
        #expect(try planner.owners(
            roots: detection.roots.map(\.id), ambiguous: [], paths: ["a.txt", "vendor/lib/b.c", "vendor/c.txt"]
        ) == ["", "vendor/lib", ""])

        let snapshot = try planner.decodeReply(
            .status(includeIgnored: false), capabilities: ["status": 1],
            reply: VcsTestData.statusReply([("z.txt", "modified"), ("a.txt", "added")]), as: VcsStatusSnapshot.self
        )
        #expect(snapshot.changes.map(\.path) == ["a.txt", "z.txt"])
        do {
            _ = try planner.decodeReply(
                .status(includeIgnored: false), capabilities: ["status": 1],
                reply: VcsTestData.statusReply([("a.txt", "obstructed")]), as: VcsStatusSnapshot.self
            )
            Issue.record("Core accepted an unknown status")
        } catch let failure as VcsProviderFailure {
            #expect(failure.code == "plugin.vcs.invalidOutput")
        }
    }

    /// A VCS client that cannot be found is the contract's
    /// `vcs.tool.unavailable`, so the tool window leads with its install hint.
    @Test
    func aVcsClientThatCannotBeFoundIsReportedAsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-vcs-tool-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let packageURL = root.appendingPathComponent("package", isDirectory: true)
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let object = try #require(
            try JSONSerialization.jsonObject(with: VcsTestData.svnProviderManifest()) as? [String: Any]
        )
        _ = try DeclarativePluginTestSupport.writePackage(at: packageURL, manifest: object)
        let entry = packageURL.appendingPathComponent("provider/svn-provider.mjs")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: entry)
        let operations = DeclarativePluginTestSupport.operations
        let descriptor = try operations.validate(manifest: Data(contentsOf: packageURL.appendingPathComponent("plugin.json")))
        let sessions = MacVcsProviderSessions(
            launchResolver: MacPluginLanguageServerLaunchResolver(
                planner: operations,
                directories: MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true)),
                settings: InMemoryPluginSettings()
            ),
            tools: VcsTestTools(),
            versionChecker: operations,
            runtime: VcsTestToolRuntime(),
            core: RustCoreBridge(),
            processRegistry: nil,
            endBackendProcesses: { _, _ in }
        )
        let target = VcsProviderTarget(
            pluginID: descriptor.id.rawValue, vcs: "svn", manifest: descriptor.normalizedManifest,
            packageURL: packageURL, workspaceURL: workspaceURL
        )
        defer { sessions.retainProviders { _ in false } }

        do {
            _ = try await sessions.negotiation(for: target)
            Issue.record("The provider started without its VCS client")
        } catch let failure as VcsProviderFailure {
            #expect(failure.code == "vcs.tool.unavailable")
            #expect(failure.message == VcsTestTools.NotFound().localizedDescription)
        }
    }

    @Test
    func installReviewShowsTheProviderCommandClientAndNetworkUse() throws {
        let review = try PluginMarketplaceTestSupport.evaluator.installReview(
            manifest: VcsTestData.svnProviderManifest(),
            expectedID: nil, expectedVersion: nil, approvedPrograms: nil
        )
        let provider = try #require(review.programs.first { $0.kind == .runtimeVcsProvider })
        #expect(provider.vcs == "svn")
        #expect(provider.tool == "node")
        #expect(provider.vcsClientCommands == ["svn"])
        #expect(provider.mayUseNetwork)

        let description = PluginMarketplacePresentation.programDescription(provider, locale: Locale(identifier: "en"))
        #expect(description.title == "svn provider (runs with node)")
        let lines = description.detail.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("node ") == true, "\(lines)")
        #expect(lines.first?.contains("svn-provider.mjs") == true, "\(lines)")
        #expect(lines.dropFirst() == ["Client: svn", "May connect to the repository server"])
    }
}

/// The provider feature through the production app model: project tree
/// moves and the project window's teardown.
@Suite("VCS providers in the app model", .serialized)
@MainActor
struct VcsProviderAppModelTests {
    /// A tracked file goes to the provider, an unversioned one stays a plain
    /// disk move.
    @Test
    func projectTreeMovesGoThroughTheProviderThatTracksTheFile() async throws {
        let root = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("beta".utf8).write(to: root.appendingPathComponent("b.txt"))
        func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }

        let fixture = try VcsFeatureFixture(workspaceURL: root, roots: [("", "svn")])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([("b.txt", "unversioned")])
        // Like `svn move`, the provider moves the file itself.
        fixture.providers.onFileOperation = { operation, rootPath in
            guard case .move(let from, let to) = operation else { return }
            let base = URL(fileURLWithPath: rootPath)
            try FileManager.default.moveItem(at: base.appendingPathComponent(from), to: base.appendingPathComponent(to))
        }
        let model = Self.makeModel(fixture)
        defer { model.workspaceFeature.reset() }

        model.openProjectDirectly(root)
        #expect(await awaitChange(on: model) { model.projectFiles.contains(url("b.txt")) })
        model.loadVcsProviders(at: root)
        #expect(await fixture.settled())
        #expect(await awaitChange(on: fixture.feature) { fixture.feature.treeStatus.status(for: url("b.txt")) != nil })

        await model.moveProjectItems([url("a.txt")], to: url("docs"))
        #expect(fixture.providers.requests.contains(.init(operation: .move(from: "a.txt", to: "docs/a.txt"), root: root.path)))
        #expect(FileManager.default.fileExists(atPath: url("docs/a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: url("a.txt").path))

        await model.moveProjectItems([url("b.txt")], to: url("docs"))
        #expect(fixture.providers.requests.filter { $0.operation.name == "fileOperation" }.count == 1)
        #expect(FileManager.default.fileExists(atPath: url("docs/b.txt").path))
        // Not tracking a file is no failure; the disk move reports as usual.
        #expect(fixture.feature.failure == nil)
    }

    /// Closing the native project window ends the session without closing
    /// the workspace. The workspace's providers stop all the same, without
    /// waiting for a status read still in flight, and a workspace load that
    /// lands after the close does not start them again.
    @Test
    func closingTheProjectWindowStopsTheWorkspaceProviders() async throws {
        let root = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("a.txt").standardizedFileURL
        try Data("alpha".utf8).write(to: file)
        let fixture = try VcsFeatureFixture(workspaceURL: root, roots: [("", "svn")])
        defer { fixture.close() }
        fixture.providers.replies["status"] = try VcsTestData.statusReply([("a.txt", "modified")])
        let model = Self.makeModel(fixture)
        defer { model.workspaceFeature.reset() }

        model.openProjectDirectly(root)
        #expect(await awaitChange(on: model) { model.projectFiles.contains(file) })
        model.loadVcsProviders(at: root)
        #expect(await fixture.settled())
        #expect(fixture.providers.running.map(\.workspaceURL) == [root])
        let statusHeld = TestGate()
        fixture.providers.holds["status"] = statusHeld
        defer { statusHeld.open() }
        let feature = fixture.feature
        feature.refresh("")
        #expect(feature.root("")?.isRefreshing == true)

        await model.shutdownProjectSession()
        // A scan that was still loading the workspace finishes afterwards.
        model.loadVcsProviders(at: root)

        #expect(fixture.providers.running.isEmpty)
        #expect(feature.workspaceURL == nil)
        #expect(feature.roots.isEmpty)
        #expect(!feature.isDetecting)
    }

    private static func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-vcs-model-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeModel(_ fixture: VcsFeatureFixture) -> AppModel {
        let store = VcsTestKeyValueStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode, platformUI: VcsMoveTestUI()
        ).services
        services.vcsProviders = fixture.feature
        return AppModel(settings: settings, services: services)
    }
}

// MARK: - Test doubles

private enum VcsTestData {
    static let pluginID = "dev.example.svn"

    /// The contract's Subversion provider manifest. The real plugin is a
    /// community plugin in its own repository.
    static func svnProviderManifest() throws -> Data {
        try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/svn-provider.plugin.json"))
    }

    static func detection(
        roots: [(id: String, vcs: String)],
        workspaceURL: URL,
        ambiguous: [String] = [],
        unusedMappings: [VcsRootMapping] = []
    ) throws -> VcsDetection {
        let object: [String: Any] = [
            "providers": [
                [
                    "vcs": "svn", "displayName": "Subversion",
                    "origin": ["kind": "plugin", "pluginID": pluginID],
                    "markers": [["name": ".svn", "type": "directory"]], "metadataPaths": [".svn/wc.db"]
                ],
                [
                    "vcs": "git", "displayName": "Git", "origin": ["kind": "builtIn"],
                    "markers": [["name": ".git", "type": "directory"]]
                ]
            ],
            "roots": roots.map { root -> [String: Any] in
                let path = root.id.isEmpty ? workspaceURL.path : workspaceURL.appendingPathComponent(root.id).path
                return ["id": root.id, "vcs": root.vcs, "path": path, "mapped": false]
            },
            "ambiguous": ambiguous.map { ["id": $0, "vcs": ["git", "svn"]] },
            "unusedMappings": unusedMappings.map { ["id": $0.id, "vcs": $0.vcs] },
            "truncated": false, "rejected": [], "conflicts": []
        ]
        return try JSONDecoder().decode(VcsDetection.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func json(_ object: Any) throws -> ToolingJSONValue {
        try JSONDecoder().decode(ToolingJSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func statusReply(_ changes: [(path: String, status: String)]) throws -> ToolingJSONValue {
        try json([
            "head": [
                "revision": ["id": "7", "display": "r7", "kind": "number"],
                "branch": "trunk", "location": "file:///repo/trunk"
            ],
            "changes": changes.map { ["path": $0.path, "oldPath": NSNull(), "status": $0.status, "flags": []] },
            "truncated": false
        ])
    }
}

/// Stands in for Rust Core: detection answers from a fixed value, ownership
/// follows Core's deepest-root rule, replies decode as sent.
private final class FakeVcsPlanner: VcsRootPlanning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDetection: VcsDetection
    private var detections = 0
    private var mappings: [VcsRootMapping] = []
    private var hold: (paths: Set<String>, entered: TestGate, released: TestGate)?
    private var holdTimedOut = false

    init(detection: VcsDetection) {
        storedDetection = detection
    }

    var detection: VcsDetection {
        get { lock.withLock { storedDetection } }
        set { lock.withLock { storedDetection = newValue } }
    }

    var detectCount: Int { lock.withLock { detections } }
    var lastMappings: [VcsRootMapping] { lock.withLock { mappings } }
    var ownersTimedOut: Bool { lock.withLock { holdTimedOut } }

    /// Ownership asked for any of `paths` opens `entered`, then answers once
    /// `released` opens.
    var heldOwners: (paths: Set<String>, entered: TestGate, released: TestGate)? {
        get { lock.withLock { hold } }
        set { lock.withLock { hold = newValue } }
    }

    func detectRoots(workspaceURL: URL, manifests: [Data], mappings: [VcsRootMapping]) throws -> VcsDetection {
        lock.withLock {
            detections += 1
            self.mappings = mappings
            return storedDetection
        }
    }

    func owners(roots: [String], ambiguous: [String], paths: [String]) throws -> [String?] {
        if let hold = heldOwners, paths.contains(where: hold.paths.contains) {
            hold.entered.open()
            // This synchronous protocol runs on the feature's detached ownership task.
            let released = hold.released.waitSynchronously(timeout: 5)
            lock.withLock { holdTimedOut = holdTimedOut || !released }
        }
        func contains(_ id: String, _ path: String) -> Bool {
            id.isEmpty || id.hasPrefix("..") || path == id || path.hasPrefix(id + "/")
        }
        func depth(_ id: String) -> Int {
            id.isEmpty ? 0 : id.split(separator: "/").count * (id.hasPrefix("..") ? -1 : 1)
        }
        return paths.map { path in
            let root = roots.filter { contains($0, path) }.max { depth($0) < depth($1) }
            let directory = ambiguous.filter { contains($0, path) }.map(depth).max()
            if let root, let directory, directory > depth(root) { return nil }
            return root
        }
    }

    func decodeReply<Value: Decodable>(
        _ operation: VcsOperation,
        capabilities: [String: Int],
        reply: ToolingJSONValue,
        as type: Value.Type
    ) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(reply))
    }
}

/// Provider processes that answer every capability from canned replies.
@MainActor
private final class FakeVcsProviders: VcsProviderRequesting {
    struct Request: Equatable {
        let operation: VcsOperation
        let root: String
    }

    var replies: [String: ToolingJSONValue] = [:]
    var failures: [String: VcsProviderFailure] = [:]
    /// Requests that wait for the gate before answering.
    var holds: [String: TestGate] = [:]
    var onFileOperation: ((VcsOperation, String) throws -> Void)?
    private(set) var requests: [Request] = []
    private(set) var retainCount = 0
    /// Targets that answered a request and were not stopped since.
    private(set) var running: Set<VcsProviderTarget> = []

    func statusCount(root: String) -> Int {
        requests.filter { $0.operation.name == "status" && $0.root == root }.count
    }

    func negotiation(for target: VcsProviderTarget) async throws -> VcsProviderNegotiation {
        Self.negotiation(target.vcs)
    }

    func send(
        _ operation: VcsOperation,
        root: String,
        to target: VcsProviderTarget,
        timeout: Duration
    ) async throws -> VcsProviderReply {
        requests.append(Request(operation: operation, root: root))
        running.insert(target)
        if let hold = holds[operation.name] {
            _ = await hold.waitUntilOpen(timeout: .seconds(5))
        }
        if let failure = failures[operation.name] { throw failure }
        if operation.name == "fileOperation" { try onFileOperation?(operation, root) }
        return VcsProviderReply(value: replies[operation.name] ?? .object([:]), negotiation: Self.negotiation(target.vcs))
    }

    func retainProviders(_ keep: (VcsProviderTarget) -> Bool) {
        retainCount += 1
        running = running.filter(keep)
    }

    private static func negotiation(_ vcs: String) -> VcsProviderNegotiation {
        VcsProviderNegotiation(
            vcs: vcs, capabilities: Dictionary(uniqueKeysWithValues: VcsCapability.allCases.map { ($0.rawValue, 1) })
        )
    }
}

/// Metadata directory watchers that deliver only what a test sends.
private final class FakeMetadataWatchers: DirectoryWatcherFactory, @unchecked Sendable {
    final class Watcher: DirectoryChangeSource, @unchecked Sendable {
        let directory: URL
        let onChange: @Sendable (DirectoryChangeBatch) -> Void
        private(set) var isRunning = false

        init(directory: URL, onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) {
            self.directory = directory
            self.onChange = onChange
        }

        func start() { isRunning = true }
        func stop() { isRunning = false }
    }

    private(set) var watchers: [Watcher] = []

    /// The paths of the directories watched now.
    var running: [String] { watchers.filter(\.isRunning).map(\.directory.path).sorted() }

    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource {
        let watcher = Watcher(directory: configuration.workspaceRoot, onChange: onChange)
        watchers.append(watcher)
        return watcher
    }

    /// Delivers each path to the running watcher of the directory holding it.
    func deliver(_ urls: [URL]) {
        for watcher in watchers where watcher.isRunning {
            let paths = urls.map(\.path).filter { $0.hasPrefix(watcher.directory.path + "/") }
            if !paths.isEmpty { watcher.onChange(DirectoryChangeBatch(workspacePaths: paths)) }
        }
    }

    func deliver(_ batch: DirectoryChangeBatch) {
        watchers.filter(\.isRunning).forEach { $0.onChange(batch) }
    }
}

/// A feature model over the fakes. The refresh delay passes at once and
/// the clock moves only when a test advances it.
@MainActor
private final class VcsFeatureFixture {
    let workspaceURL: URL
    let planner: FakeVcsPlanner
    let providers = FakeVcsProviders()
    let metadataWatchers = FakeMetadataWatchers()
    let files = VcsTestFiles()
    let keyValues = VcsTestKeyValueStore()
    let clock = VcsTestClock()
    let feature: VcsProvidersFeatureModel

    init(
        workspaceURL: URL = URL(fileURLWithPath: "/virtual/workspace", isDirectory: true),
        roots: [(id: String, vcs: String)],
        ambiguous: [String] = []
    ) throws {
        self.workspaceURL = workspaceURL.standardizedFileURL
        planner = FakeVcsPlanner(detection: try VcsTestData.detection(
            roots: roots, workspaceURL: self.workspaceURL, ambiguous: ambiguous
        ))
        let clock = clock
        let files = files
        feature = VcsProvidersFeatureModel(
            planner: planner,
            providers: providers,
            mappingStore: MacVcsRootMappingStore(store: keyValues),
            fileExists: { files.exists($0) },
            sleep: { _ in try Task.checkCancellation() },
            now: { clock.now },
            metadataWatcherFactory: metadataWatchers,
            sources: {
                [VcsProviderPluginSource(
                    pluginID: VcsTestData.pluginID, manifest: Data("{}".utf8),
                    packageURL: URL(fileURLWithPath: "/virtual/plugin", isDirectory: true),
                    providers: [DeclarativeVcsProvider(id: "svn", displayName: "Subversion")]
                )]
            }
        )
    }

    func url(_ path: String) -> URL {
        workspaceURL.appendingPathComponent(path).standardizedFileURL
    }

    /// Reports changed workspace entries, as the workspace watcher does.
    func changed(_ paths: String...) {
        feature.workspaceFilesChanged(paths.map { WorkspaceFileChange(fileURL: url($0), kind: .changed) })
    }

    /// Reports created workspace entries, as the workspace watcher does.
    func created(_ paths: String...) {
        feature.workspaceFilesChanged(paths.map { WorkspaceFileChange(fileURL: url($0), kind: .created) })
    }

    /// Opens the workspace and waits until every root has read its status.
    func open() async -> Bool {
        feature.reset(workspaceURL: workspaceURL)
        return await settled()
    }

    /// Waits until detection and every status read have finished and
    /// `condition` holds, so a refresh that should not happen would have
    /// been requested by then.
    func settled(_ condition: @escaping @MainActor @Sendable () -> Bool = { true }) async -> Bool {
        await awaitChange(on: feature) { [feature] in
            condition() && !feature.isDetecting && !feature.roots.isEmpty
                && feature.roots.allSatisfy { $0.snapshot != nil && !$0.isRefreshing }
        }
    }

    func close() {
        feature.reset(workspaceURL: nil)
    }
}

/// Finds the provider's runtime but no VCS client.
private final class VcsTestTools: BuildToolResolving {
    struct NotFound: LocalizedError {
        var errorDescription: String? { "svn was not found." }
    }

    func resolve(
        _ invocation: BuildInvocation, displayName _: String, workspaceURL _: URL,
        checkVersion _: @escaping @Sendable (String?, String) throws -> BuildVersionCheck
    ) async throws -> ResolvedBuildTool {
        guard invocation.executables == [.runtime("node")] else { throw NotFound() }
        return ResolvedBuildTool(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"), environment: [:], executesProjectCode: false, version: nil
        )
    }
}

private final class VcsTestToolRuntime: LanguageToolRuntimePort {
    func executableOnPath(_: String) -> URL? { nil }
    func executableURL(at _: String) -> URL? { nil }
    func executableCandidates(_: String) -> [RuntimeToolCandidate] { [] }
    func languageToolProcessEnvironment(runtimeTools _: [String]) -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { name }
}

/// The paths a marker lookup finds, and the lookups made.
private final class VcsTestFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var existing: Set<String> = []
    private var recorded: [String] = []
    private var waiter: (count: Int, gate: TestGate)?

    var lookups: [String] { lock.withLock { recorded } }

    func add(_ urls: URL...) {
        lock.withLock { existing.formUnion(urls.map(\.path)) }
    }

    /// A gate that opens once `count` lookups have been made.
    func gate(afterLookups count: Int) -> TestGate {
        let gate = TestGate()
        let reached = lock.withLock {
            waiter = (count, gate)
            return recorded.count >= count
        }
        if reached { gate.open() }
        return gate
    }

    func exists(_ url: URL) -> Bool {
        let (found, gate) = lock.withLock { () -> (Bool, TestGate?) in
            recorded.append(url.path)
            let gate = waiter.flatMap { recorded.count >= $0.count ? $0.gate : nil }
            return (existing.contains(url.path), gate)
        }
        gate?.open()
        return found
    }
}

private final class VcsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(by duration: Duration) {
        lock.withLock { instant += duration }
    }
}

private final class VcsTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    var isEmpty: Bool { values.isEmpty }

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class VcsMoveTestUI: PlatformUI {
    func copyFilesToClipboard(_ urls: [URL]) -> Bool { false }
    func fileURLsFromClipboard() -> [URL] { [] }
    func activateApplication() {}
    func chooseDirectory(title: String, prompt: String) -> URL? { nil }
    func chooseFile(title: String, prompt: String) -> URL? { nil }
    func revealInFileBrowser(_ url: URL) {}
    func open(_ url: URL) {}
    func copyToClipboard(_ value: String) {}
    func markdownImageFromClipboard() -> MarkdownImageSource? { nil }
    func startAccessingProject(_ url: URL) -> Bool { false }
    func stopAccessingProject(_ url: URL) {}
}
