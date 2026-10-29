import Darwin
import Foundation
import LitheCoreContracts
import LitheSearchModule
import Testing
@testable import Lithe

/// Host-internal plugin workspace file service (API-06/07/08): path safety,
/// paging, reads, watch ownership and search adaptation. Every test owns a
/// temporary directory removed in `defer`; watch tests use a fake change
/// source and a manually drained delivery, so nothing waits on FSEvents.
@Suite("Plugin workspace file service")
struct PluginWorkspaceFileServiceTests {
    private static let caller = PluginWorkspaceCaller(pluginID: "sample.files", sessionID: "session-1")
    private static let otherCaller = PluginWorkspaceCaller(pluginID: "sample.other", sessionID: "session-2")

    // MARK: Path validation

    @Test func pathValidationRejectsEscapesAndNormalizesToNFC() throws {
        #expect(try MacWorkspaceSecurePath.components(of: "") == [])
        #expect(try MacWorkspaceSecurePath.components(of: "src/main.swift") == ["src", "main.swift"])
        #expect(try MacWorkspaceSecurePath.components(of: "e\u{301}.txt") == ["\u{e9}.txt"])
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: "../etc") } == .invalidPath(.parentTraversal))
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: "a/../../b") } == .invalidPath(.parentTraversal))
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: "/etc/passwd") } == .invalidPath(.absolute))
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: "a//b") } == .invalidPath(.emptyComponent))
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: "a/") } == .invalidPath(.emptyComponent))
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: "./a") } == .invalidPath(.currentDirectoryComponent))
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: "a\u{0}b") } == .invalidPath(.nulCharacter))
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: String(repeating: "x", count: 256)) } == .invalidPath(.componentTooLong))
        let longPath = Array(repeating: String(repeating: "x", count: 200), count: 6).joined(separator: "/")
        #expect(Self.rejection { try MacWorkspaceSecurePath.components(of: longPath) } == .invalidPath(.pathTooLong))
    }

    @Test func serviceRejectsTraversalBeforeTouchingDisk() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        try workspace.write("inside.txt", "inside")
        let service = Self.makeService()
        let root = workspace.root(id: "w1")

        #expect(await Self.failure { try await service.readFile("../inside.txt", in: root, caller: Self.caller, maximumBytes: nil) }
            == .invalidPath(.parentTraversal))
        #expect(await Self.failure { try await service.readDirectory("/", in: root, caller: Self.caller, cursor: nil, limit: nil) }
            == .invalidPath(.absolute))
        #expect(await Self.failure { try await service.stat("a/./b", in: root, caller: Self.caller) }
            == .invalidPath(.currentDirectoryComponent))
    }

    @Test func listingAndReadingUseNFCResourcePaths() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let decomposed = "cafe\u{301}.txt"
        try workspace.write(decomposed, "bonjour")
        let service = Self.makeService()
        let root = workspace.root(id: "w1")

        let page = try await service.readDirectory("", in: root, caller: Self.caller, cursor: nil, limit: nil)
        #expect(page.entries.map(\.resource.path) == ["caf\u{e9}.txt"])
        #expect(page.entries.first?.resource.path.utf8.count == "caf\u{e9}.txt".utf8.count)

        let contents = try await service.readFile(decomposed, in: root, caller: Self.caller, maximumBytes: nil)
        #expect(contents.resource == PluginWorkspaceResource(rootID: "w1", path: "caf\u{e9}.txt"))
        #expect(contents.content == .text("bonjour", encoding: "utf-8"))
    }

    // MARK: Symbolic links

    @Test func symbolicLinksOutOfRootAreNeverFollowed() async throws {
        let workspace = try TemporaryWorkspace()
        let outside = try TemporaryWorkspace()
        defer {
            workspace.remove()
            outside.remove()
        }
        try outside.write("secret.txt", "secret")
        try workspace.write("visible.txt", "visible")
        try FileManager.default.createSymbolicLink(at: workspace.url("linked-dir"), withDestinationURL: outside.base)
        try FileManager.default.createSymbolicLink(at: workspace.url("linked-file"), withDestinationURL: outside.url("secret.txt"))
        let service = Self.makeService()
        let root = workspace.root(id: "w1")

        #expect(await Self.failure { try await service.readDirectory("linked-dir", in: root, caller: Self.caller, cursor: nil, limit: nil) }
            == .symbolicLinkNotFollowed)
        #expect(await Self.failure { try await service.readFile("linked-dir/secret.txt", in: root, caller: Self.caller, maximumBytes: nil) }
            == .symbolicLinkNotFollowed)
        #expect(await Self.failure { try await service.readFile("linked-file", in: root, caller: Self.caller, maximumBytes: nil) }
            == .symbolicLinkNotFollowed)
        #expect(await Self.failure { try await service.stat("linked-dir/secret.txt", in: root, caller: Self.caller) }
            == .symbolicLinkNotFollowed)

        let link = try await service.stat("linked-file", in: root, caller: Self.caller)
        #expect(link.kind == .symbolicLink)
        let listing = try await service.readDirectory("", in: root, caller: Self.caller, cursor: nil, limit: nil)
        #expect(listing.entries.map(\.name) == ["visible.txt"])
    }

    @Test func directorySwappedForLinkBeforeOpenIsRejected() throws {
        let workspace = try TemporaryWorkspace()
        let outside = try TemporaryWorkspace()
        defer {
            workspace.remove()
            outside.remove()
        }
        try workspace.write("a/b/marker.txt", "inside")
        try outside.write("b/marker.txt", "outside")
        let rootDescriptor = try MacWorkspaceSecurePath.openRoot(workspace.base)
        defer { Darwin.close(rootDescriptor) }

        // Checked once as a directory, then replaced by a link before use.
        let first = try MacWorkspaceSecurePath.openDirectory(["a", "b"], below: rootDescriptor)
        Darwin.close(first)
        try FileManager.default.moveItem(at: workspace.url("a"), to: workspace.url("a-moved"))
        try FileManager.default.createSymbolicLink(at: workspace.url("a"), withDestinationURL: outside.base)

        #expect(Self.rejection { try MacWorkspaceSecurePath.openDirectory(["a", "b"], below: rootDescriptor) } == .symbolicLinkNotFollowed)
    }

    @Test func linkSwappedInMidWalkCannotRedirectTheHeldDescriptor() throws {
        let workspace = try TemporaryWorkspace()
        let outside = try TemporaryWorkspace()
        defer {
            workspace.remove()
            outside.remove()
        }
        try workspace.write("a/b/marker.txt", "inside")
        try outside.write("b/marker.txt", "outside")
        let rootDescriptor = try MacWorkspaceSecurePath.openRoot(workspace.base)
        defer { Darwin.close(rootDescriptor) }

        var swapError: (any Error)?
        let directory = try MacWorkspaceSecurePath.openDirectory(["a", "b"], below: rootDescriptor) { index in
            guard index == 0 else { return }
            // `a` is open; replace it by a link to the outside tree before
            // `b` is resolved.
            do {
                try FileManager.default.moveItem(at: workspace.url("a"), to: workspace.url("a-moved"))
                try FileManager.default.createSymbolicLink(at: workspace.url("a"), withDestinationURL: outside.base)
            } catch {
                swapError = error
            }
        }
        defer { Darwin.close(directory) }
        #expect(swapError == nil)
        #expect(try Self.readText(named: "marker.txt", in: directory) == "inside")
    }

    // MARK: Paging and visibility

    @Test func directoryPagesFollowTreeOrderWithoutDuplicates() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        for index in 1...12 { try workspace.write("file\(index).txt", "\(index)") }
        for index in 1...3 { try workspace.makeDirectory("dir\(index)") }
        let service = Self.makeService()
        let root = workspace.root(id: "w1")

        var names: [String] = []
        var kinds: [PluginWorkspaceEntryKind] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await service.readDirectory("", in: root, caller: Self.caller, cursor: cursor, limit: 4)
            #expect(page.entries.count <= 4)
            #expect(page.directory == PluginWorkspaceResource(rootID: "w1", path: ""))
            names += page.entries.map(\.name)
            kinds += page.entries.map(\.kind)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(pages == 4)
        #expect(names == ["dir1", "dir2", "dir3"] + (1...12).map { "file\($0).txt" })
        #expect(Set(names).count == names.count)
        #expect(kinds.prefix(3).allSatisfy { $0 == .directory })
    }

    @Test func cursorIsBoundToItsDirectoryAndRejectsTampering() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        for index in 1...3 { try workspace.write("src/f\(index).txt", "x") }
        try workspace.write("docs/readme.md", "x")
        let service = Self.makeService()
        let root = workspace.root(id: "w1")

        let first = try await service.readDirectory("src", in: root, caller: Self.caller, cursor: nil, limit: 1)
        let cursor = try #require(first.nextCursor)
        let second = try await service.readDirectory("src", in: root, caller: Self.caller, cursor: cursor, limit: 1)
        #expect(second.entries.map(\.resource.path) == ["src/f2.txt"])

        #expect(await Self.failure { try await service.readDirectory("docs", in: root, caller: Self.caller, cursor: cursor, limit: 1) }
            == .invalidCursor)
        #expect(await Self.failure { try await service.readDirectory("src", in: root, caller: Self.caller, cursor: "not a cursor", limit: 1) }
            == .invalidCursor)
        let otherRoot = workspace.root(id: "w2")
        #expect(await Self.failure { try await service.readDirectory("src", in: otherRoot, caller: Self.caller, cursor: cursor, limit: 1) }
            == .invalidCursor)
    }

    @Test func hugeDirectoryIsCappedAndPagesAreClamped() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        for index in 1...12 { try workspace.write("big/f\(index)", "") }
        for index in 1...8 { try workspace.write("small/f\(index)", "") }
        var budgets = PluginWorkspaceFileBudgets()
        budgets.maximumDirectoryScanEntries = 10
        budgets.maximumDirectoryPageSize = 5
        let service = Self.makeService(budgets: budgets)
        let root = workspace.root(id: "w1")

        #expect(await Self.failure { try await service.readDirectory("big", in: root, caller: Self.caller, cursor: nil, limit: nil) }
            == .limitExceeded(.directoryEntries))
        let page = try await service.readDirectory("small", in: root, caller: Self.caller, cursor: nil, limit: 10_000)
        #expect(page.entries.count == 5)
        #expect(page.nextCursor != nil)
    }

    @Test func listingsHideWhatTheProjectTreeHidesButExplicitReadsWork() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        try workspace.write("node_modules/pkg/index.js", "x")
        try workspace.write(".DS_Store", "x")
        try workspace.write("generated.log", "x")
        try workspace.write("main.swift", "x")
        let service = Self.makeService()
        let rules = FileVisibilityRules(hiddenDirectoryNames: [], hiddenFilePatterns: ["*.log"])
        let root = workspace.root(id: "w1", visibilityRules: rules)

        let listing = try await service.readDirectory("", in: root, caller: Self.caller, cursor: nil, limit: nil)
        #expect(listing.entries.map(\.name) == ["main.swift"])
        let hidden = try await service.readFile("generated.log", in: root, caller: Self.caller, maximumBytes: nil)
        #expect(hidden.content == .text("x", encoding: "utf-8"))
    }

    // MARK: Reading

    @Test func binaryFileIsReturnedAsBytes() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let bytes = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00, 0x7F, 0x80])
        try workspace.write("image.bin", bytes)
        let service = Self.makeService()

        let contents = try await service.readFile("image.bin", in: workspace.root(id: "w1"), caller: Self.caller, maximumBytes: nil)
        #expect(contents.content == .binary(bytes))
        #expect(contents.byteCount == bytes.count)
        #expect(!contents.isTruncated)
        #expect(contents.identity == MacDocumentEncoding.identity(bytes))
        #expect(contents.source == .disk)
    }

    @Test func readOverLimitIsTruncatedAtACharacterBoundary() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        try workspace.write("notes.txt", "abc\u{4e2d}def")
        var budgets = PluginWorkspaceFileBudgets()
        budgets.maximumReadBytes = 8
        let service = Self.makeService(budgets: budgets)
        let root = workspace.root(id: "w1")

        let cut = try await service.readFile("notes.txt", in: root, caller: Self.caller, maximumBytes: 5)
        #expect(cut.isTruncated)
        #expect(cut.byteCount == 5)
        #expect(cut.identity == nil)
        #expect(cut.content == .text("abc", encoding: "utf-8"))

        let clamped = try await service.readFile("notes.txt", in: root, caller: Self.caller, maximumBytes: 1_000)
        #expect(clamped.byteCount == 8)
        #expect(clamped.isTruncated)

        try workspace.write("short.txt", "abc")
        let whole = try await service.readFile("short.txt", in: root, caller: Self.caller, maximumBytes: 3)
        #expect(!whole.isTruncated)
        #expect(whole.identity == MacDocumentEncoding.identity(Data("abc".utf8)))
    }

    @Test func readingADirectoryOrMissingFileFails() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        try workspace.makeDirectory("src")
        let service = Self.makeService()
        let root = workspace.root(id: "w1")

        #expect(await Self.failure { try await service.readFile("src", in: root, caller: Self.caller, maximumBytes: nil) } == .notRegularFile)
        #expect(await Self.failure { try await service.readFile("", in: root, caller: Self.caller, maximumBytes: nil) } == .notRegularFile)
        #expect(await Self.failure { try await service.readFile("missing.txt", in: root, caller: Self.caller, maximumBytes: nil) } == .notFound)
        let directory = try await service.stat("src", in: root, caller: Self.caller)
        #expect(directory.kind == .directory)
        #expect(directory.resource == PluginWorkspaceResource(rootID: "w1", path: "src"))
    }

    // MARK: Roots

    @Test func remoteAuthorityAndRemotePlaceholdersAreRejected() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let service = Self.makeService(isRemote: { $0.lastPathComponent == "placeholder" })
        let remote = PluginWorkspaceRoot(id: "r1", url: workspace.base, authority: .remote("ssh-remote+host"), generation: 1)
        try workspace.makeDirectory("placeholder")
        let placeholder = PluginWorkspaceRoot(id: "r2", url: workspace.url("placeholder"), authority: .local, generation: 1)

        for root in [remote, placeholder] {
            #expect(await Self.failure { try await service.readDirectory("", in: root, caller: Self.caller, cursor: nil, limit: nil) }
                == .unsupportedAuthority)
            #expect(await Self.failure { try await service.readFile("a.txt", in: root, caller: Self.caller, maximumBytes: nil) }
                == .unsupportedAuthority)
            #expect(await Self.failure { try await service.findText(.init(pattern: "x"), in: root, caller: Self.caller, cursor: nil, limit: nil) }
                == .unsupportedAuthority)
            #expect(Self.rejection { _ = try service.watch("", recursive: true, in: root, caller: Self.caller) { _ in } }
                == .unsupportedAuthority)
        }
        #expect(service.activeWatchStreamCount == 0)
    }

    @Test func closedAndOlderGenerationsAreStale() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        try workspace.write("a.txt", "a")
        let service = Self.makeService()

        _ = try await service.stat("a.txt", in: workspace.root(id: "w1", generation: 2), caller: Self.caller)
        #expect(await Self.failure { try await service.stat("a.txt", in: workspace.root(id: "w1", generation: 1), caller: Self.caller) }
            == .staleWorkspace)
        service.closeWorkspace(rootID: "w1", generation: 2)
        #expect(await Self.failure { try await service.stat("a.txt", in: workspace.root(id: "w1", generation: 2), caller: Self.caller) }
            == .staleWorkspace)
        _ = try await service.stat("a.txt", in: workspace.root(id: "w1", generation: 3), caller: Self.caller)
    }

    @Test func twoWorkspacesNeverShareResultsOrEvents() async throws {
        let first = try TemporaryWorkspace()
        let second = try TemporaryWorkspace()
        defer {
            first.remove()
            second.remove()
        }
        try first.write("one.txt", "1")
        try second.write("two.txt", "2")
        let watchers = FakeChangeSources()
        let delivery = ManualDelivery()
        let service = Self.makeService(watchers: watchers, delivery: delivery)
        let rootOne = first.root(id: "w1")
        let rootTwo = second.root(id: "w2")

        let listingOne = try await service.readDirectory("", in: rootOne, caller: Self.caller, cursor: nil, limit: nil)
        let listingTwo = try await service.readDirectory("", in: rootTwo, caller: Self.caller, cursor: nil, limit: nil)
        #expect(listingOne.entries.map(\.resource) == [PluginWorkspaceResource(rootID: "w1", path: "one.txt")])
        #expect(listingTwo.entries.map(\.resource) == [PluginWorkspaceResource(rootID: "w2", path: "two.txt")])

        let eventsOne = EventRecorder()
        let eventsTwo = EventRecorder()
        let subscriptionOne = try service.watch("", recursive: true, in: rootOne, caller: Self.caller, onEvent: eventsOne.record)
        let subscriptionTwo = try service.watch("", recursive: true, in: rootTwo, caller: Self.caller, onEvent: eventsTwo.record)
        defer {
            subscriptionOne.dispose()
            subscriptionTwo.dispose()
        }
        #expect(watchers.sources.count == 2)
        try watchers.sources[0].send(["one.txt"])
        delivery.drain()
        #expect(eventsOne.events.map(\.changedPaths) == [["one.txt"]])
        #expect(eventsOne.events.first?.rootID == "w1")
        #expect(eventsTwo.events.isEmpty)
    }

    // MARK: Watch

    @Test func subscriptionsShareOneSourceAndAreReleasedByOwnership() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let watchers = FakeChangeSources()
        let service = Self.makeService(watchers: watchers, delivery: ManualDelivery())
        let root = workspace.root(id: "w1")

        let first = try service.watch("", recursive: true, in: root, caller: Self.caller) { _ in }
        let second = try service.watch("src", recursive: false, in: root, caller: Self.caller) { _ in }
        _ = try service.watch("docs", recursive: true, in: root, caller: Self.otherCaller) { _ in }
        #expect(watchers.sources.count == 1)
        #expect(watchers.sources[0].isRunning)
        #expect(service.activeWatchSubscriptionCount == 3)

        first.dispose()
        first.dispose()
        #expect(service.activeWatchSubscriptionCount == 2)
        service.releaseResources(of: Self.caller)
        #expect(service.activeWatchSubscriptionCount == 1)
        #expect(watchers.sources[0].isRunning)
        second.dispose()

        service.closeWorkspace(rootID: "w1", generation: 1)
        #expect(service.activeWatchSubscriptionCount == 0)
        #expect(service.activeWatchStreamCount == 0)
        #expect(!watchers.sources[0].isRunning)
        #expect(Self.rejection { _ = try service.watch("", recursive: true, in: root, caller: Self.caller) { _ in } } == .staleWorkspace)
    }

    @Test func newGenerationReleasesOldWatchersAndDropsTheirLateEvents() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let watchers = FakeChangeSources()
        let delivery = ManualDelivery()
        let service = Self.makeService(watchers: watchers, delivery: delivery)
        let oldEvents = EventRecorder()
        let newEvents = EventRecorder()

        _ = try service.watch("", recursive: true, in: workspace.root(id: "w1", generation: 1), caller: Self.caller, onEvent: oldEvents.record)
        _ = try await service.stat("", in: workspace.root(id: "w1", generation: 2), caller: Self.caller)
        #expect(service.activeWatchSubscriptionCount == 0)
        #expect(!watchers.sources[0].isRunning)

        let current = try service.watch("", recursive: true, in: workspace.root(id: "w1", generation: 2), caller: Self.caller, onEvent: newEvents.record)
        defer { current.dispose() }
        // The stopped source of generation 1 still calls back late.
        try watchers.sources[0].send(["stale.txt"], evenIfStopped: true)
        try watchers.sources[1].send(["fresh.txt"])
        delivery.drain()

        #expect(oldEvents.events.isEmpty)
        #expect(newEvents.events.map(\.changedPaths) == [["fresh.txt"]])
        #expect(newEvents.events.map(\.generation) == [2])
    }

    @Test func eventsAreCoalescedFilteredAndCollapseToRescanOnOverflow() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let watchers = FakeChangeSources()
        let delivery = ManualDelivery()
        var budgets = PluginWorkspaceFileBudgets()
        budgets.maximumPendingWatchPaths = 3
        let service = Self.makeService(budgets: budgets, watchers: watchers, delivery: delivery)
        let root = workspace.root(id: "w1")
        let recursive = EventRecorder()
        let shallow = EventRecorder()

        let all = try service.watch("", recursive: true, in: root, caller: Self.caller, onEvent: recursive.record)
        let src = try service.watch("src", recursive: false, in: root, caller: Self.caller, onEvent: shallow.record)
        defer {
            all.dispose()
            src.dispose()
        }
        let source = watchers.sources[0]

        try source.send(["src/a.swift", "src/deep/b.swift"])
        try source.send(["src/a.swift", "node_modules/pkg/index.js", "README.md"])
        #expect(delivery.pendingCount == 2)
        delivery.drain()
        #expect(recursive.events.map(\.changedPaths) == [["src/a.swift", "src/deep/b.swift", "README.md"]])
        #expect(recursive.events.map(\.sequence) == [1])
        #expect(shallow.events.map(\.changedPaths) == [["src/a.swift"]])

        try source.send(["a", "b", "c", "d"])
        delivery.drain()
        #expect(recursive.events.last?.requiresRescan == true)
        #expect(recursive.events.last?.changedPaths == [])
        #expect(recursive.events.last?.sequence == 2)

        source.sendBatch(DirectoryChangeBatch(requiresFullRescan: true))
        delivery.drain()
        #expect(shallow.events.last?.requiresRescan == true)
    }

    @Test func disposedSubscriptionReceivesNothingAlreadyQueued() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let watchers = FakeChangeSources()
        let delivery = ManualDelivery()
        let service = Self.makeService(watchers: watchers, delivery: delivery)
        let events = EventRecorder()

        let subscription = try service.watch("", recursive: true, in: workspace.root(id: "w1"), caller: Self.caller, onEvent: events.record)
        try watchers.sources[0].send(["a.txt"])
        subscription.dispose()
        delivery.drain()
        #expect(events.events.isEmpty)
        #expect(!watchers.sources[0].isRunning)
    }

    @Test func watchSubscriptionsAreCappedPerCaller() throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        var budgets = PluginWorkspaceFileBudgets()
        budgets.maximumWatchSubscriptionsPerCaller = 2
        let service = Self.makeService(budgets: budgets, watchers: FakeChangeSources(), delivery: ManualDelivery())
        let root = workspace.root(id: "w1")

        _ = try service.watch("a", recursive: true, in: root, caller: Self.caller) { _ in }
        _ = try service.watch("b", recursive: true, in: root, caller: Self.caller) { _ in }
        #expect(Self.rejection { _ = try service.watch("c", recursive: true, in: root, caller: Self.caller) { _ in } }
            == .limitExceeded(.watchSubscriptions))
        _ = try service.watch("c", recursive: true, in: root, caller: Self.otherCaller) { _ in }
        service.releaseResources(of: Self.caller)
        service.releaseResources(of: Self.otherCaller)
        #expect(service.activeWatchStreamCount == 0)
    }

    // MARK: Search

    @Test func findTextPagesDiskResultsInsideTheRootOnly() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let search = FakeSearch()
        search.textResults = { rootURL in
            [
                FileSearchResult(url: rootURL.appendingPathComponent("a.swift"), line: 3, preview: "let x = 1"),
                FileSearchResult(url: rootURL.appendingPathComponent("src/b.swift"), line: 7, preview: "x += 1"),
                FileSearchResult(url: URL(fileURLWithPath: "/elsewhere/c.swift"), line: 1, preview: "x"),
                FileSearchResult(url: rootURL.appendingPathComponent("d.swift"), line: 9, preview: "x()"),
                FileSearchResult(url: rootURL.appendingPathComponent("e.swift"), line: nil, preview: "", kind: .file),
            ]
        }
        var budgets = PluginWorkspaceFileBudgets()
        budgets.searchResultCap = 5
        let service = Self.makeService(budgets: budgets, search: search)
        let root = workspace.root(id: "w1")
        let query = PluginWorkspaceFindTextQuery(pattern: "x")

        let first = try await service.findText(query, in: root, caller: Self.caller, cursor: nil, limit: 2)
        #expect(first.matches.map(\.resource.path) == ["a.swift", "src/b.swift"])
        #expect(first.matches.map(\.line) == [3, 7])
        #expect(first.isTruncated)
        #expect(first.source == .disk)
        let cursor = try #require(first.nextCursor)
        let second = try await service.findText(query, in: root, caller: Self.caller, cursor: cursor, limit: 2)
        #expect(second.matches.map(\.resource.path) == ["d.swift"])
        #expect(second.nextCursor == nil)

        let otherQuery = PluginWorkspaceFindTextQuery(pattern: "y")
        #expect(await Self.failure { try await service.findText(otherQuery, in: root, caller: Self.caller, cursor: cursor, limit: 2) }
            == .invalidCursor)
    }

    @Test func findFilesUsesTheFileProviderAndReportsUnavailableIndex() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let search = FakeSearch()
        search.fileResults = { rootURL in
            [FileSearchResult(url: rootURL.appendingPathComponent("Sources/App.swift"), line: nil, preview: "", kind: .file)]
        }
        let service = Self.makeService(search: search)
        let root = workspace.root(id: "w1")

        let page = try await service.findFiles(.init(query: "App"), in: root, caller: Self.caller, cursor: nil, limit: nil)
        #expect(page.matches == [PluginWorkspaceFileMatch(resource: PluginWorkspaceResource(rootID: "w1", path: "Sources/App.swift"))])
        #expect(!page.isTruncated)
        #expect(search.requestedKinds == [[.file]])

        search.fileResults = { _ in nil }
        #expect(await Self.failure { try await service.findFiles(.init(query: "App"), in: root, caller: Self.caller, cursor: nil, limit: nil) }
            == .searchUnavailable)
    }

    @Test func cancelledSearchReturnsAtOnceAndConcurrencyIsBudgeted() async throws {
        let workspace = try TemporaryWorkspace()
        defer { workspace.remove() }
        let entered = TestGate()
        let release = TestGate()
        defer { release.open() }
        let search = FakeSearch()
        search.textResults = { _ in
            entered.open()
            // test-stability: bounded on the service's worker queue; the test releases the gate in defer.
            _ = release.waitSynchronously(timeout: 5)
            return []
        }
        var budgets = PluginWorkspaceFileBudgets()
        budgets.maximumConcurrentOperationsPerCaller = 1
        let service = Self.makeService(budgets: budgets, search: search)
        let root = workspace.root(id: "w1")

        let task = Task {
            try await service.findText(.init(pattern: "slow"), in: root, caller: Self.caller, cursor: nil, limit: nil)
        }
        #expect(await entered.waitUntilOpen(timeout: .seconds(5)))
        #expect(await Self.failure { try await service.stat("", in: root, caller: Self.caller) } == .limitExceeded(.concurrentOperations))
        _ = try await service.stat("", in: root, caller: Self.otherCaller)

        task.cancel()
        let result = await task.result
        #expect(Self.failure(of: result) == .cancelled)
        #expect(!release.isOpen)
    }

    // MARK: Helpers

    private static func makeService(
        budgets: PluginWorkspaceFileBudgets = .default,
        search: FakeSearch = FakeSearch(),
        watchers: FakeChangeSources = FakeChangeSources(),
        delivery: ManualDelivery = ManualDelivery(),
        isRemote: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) -> MacPluginWorkspaceFileService {
        MacPluginWorkspaceFileService(
            budgets: budgets,
            searchOperations: search,
            watcherFactory: watchers,
            isRemoteWorkspaceRoot: isRemote,
            makeWatchDelivery: { delivery }
        )
    }

    private static func failure<Value>(_ body: () async throws -> Value) async -> PluginWorkspaceFileError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? PluginWorkspaceFileError
        }
    }

    private static func rejection<Value>(_ body: () throws -> Value) -> PluginWorkspaceFileError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? PluginWorkspaceFileError
        }
    }

    private static func failure<Value>(of result: Result<Value, any Error>) -> PluginWorkspaceFileError? {
        guard case let .failure(error) = result else { return nil }
        return error as? PluginWorkspaceFileError
    }

    private static func readText(named name: String, in directory: Int32) throws -> String? {
        let file = try MacWorkspaceSecurePath.openRegularFile(named: name, in: directory)
        defer { Darwin.close(file.descriptor) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(file.descriptor, $0.baseAddress, 256) }
        guard count >= 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }
}

// MARK: - Fixtures

/// A temporary workspace directory; tests call `remove()` from `defer`.
private struct TemporaryWorkspace {
    let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-workspace-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func url(_ relativePath: String) -> URL {
        base.appendingPathComponent(relativePath)
    }

    func root(
        id: String,
        generation: UInt64 = 1,
        visibilityRules: FileVisibilityRules = .default
    ) -> PluginWorkspaceRoot {
        PluginWorkspaceRoot(id: id, url: base, authority: .local, generation: generation, visibilityRules: visibilityRules)
    }

    func write(_ relativePath: String, _ text: String) throws {
        try write(relativePath, Data(text.utf8))
    }

    func write(_ relativePath: String, _ data: Data) throws {
        let target = url(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    func makeDirectory(_ relativePath: String) throws {
        try FileManager.default.createDirectory(at: url(relativePath), withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class FakeChangeSources: DirectoryWatcherFactory, @unchecked Sendable {
    final class Source: DirectoryChangeSource, @unchecked Sendable {
        let workspaceRoot: URL
        private let onChange: @Sendable (DirectoryChangeBatch) -> Void
        private let lock = NSLock()
        private var running = false

        init(workspaceRoot: URL, onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void) {
            self.workspaceRoot = workspaceRoot
            self.onChange = onChange
        }

        var isRunning: Bool { lock.withLock { running } }
        func start() { lock.withLock { running = true } }
        func stop() { lock.withLock { running = false } }

        /// Reports workspace-relative paths as the absolute real paths
        /// FSEvents would deliver.
        func send(_ relativePaths: [String], evenIfStopped: Bool = false) throws {
            guard evenIfStopped || isRunning else { throw CocoaError(.featureUnsupported) }
            onChange(DirectoryChangeBatch(workspacePaths: relativePaths.map { workspaceRoot.appendingPathComponent($0).path }))
        }

        func sendBatch(_ batch: DirectoryChangeBatch) {
            onChange(batch)
        }
    }

    private let lock = NSLock()
    private var made: [Source] = []

    var sources: [Source] { lock.withLock { made } }

    func make(
        configuration: DirectoryWatchConfiguration,
        visibilityRules: FileVisibilityRules,
        onChange: @escaping @Sendable (DirectoryChangeBatch) -> Void
    ) -> any DirectoryChangeSource {
        let source = Source(workspaceRoot: configuration.workspaceRoot, onChange: onChange)
        lock.withLock { made.append(source) }
        return source
    }
}

/// Holds deliveries until the test drains them on its own thread.
private final class ManualDelivery: PluginWorkspaceWatchDelivery, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [@Sendable () -> Void] = []

    var pendingCount: Int { lock.withLock { queued.count } }

    func schedule(_ work: @escaping @Sendable () -> Void) {
        lock.withLock { queued.append(work) }
    }

    func drain() {
        while true {
            let next: (@Sendable () -> Void)? = lock.withLock { queued.isEmpty ? nil : queued.removeFirst() }
            guard let next else { return }
            next()
        }
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PluginWorkspaceWatchEvent] = []

    var events: [PluginWorkspaceWatchEvent] { lock.withLock { recorded } }

    var record: @Sendable (PluginWorkspaceWatchEvent) -> Void {
        { [self] event in lock.withLock { recorded.append(event) } }
    }
}

private final class FakeSearch: SearchOperations, @unchecked Sendable {
    private let lock = NSLock()
    private var textProvider: @Sendable (URL) -> [FileSearchResult]? = { _ in [] }
    private var fileProvider: @Sendable (URL) -> [FileSearchResult]? = { _ in [] }
    private var kinds: [Set<SearchResultKind>] = []

    var textResults: @Sendable (URL) -> [FileSearchResult]? {
        get { lock.withLock { textProvider } }
        set { lock.withLock { textProvider = newValue } }
    }

    var fileResults: @Sendable (URL) -> [FileSearchResult]? {
        get { lock.withLock { fileProvider } }
        set { lock.withLock { fileProvider = newValue } }
    }

    var requestedKinds: [Set<SearchResultKind>] { lock.withLock { kinds } }

    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: SearchVisibilityRules) -> [FileSearchResult]? {
        textResults(rootURL)
    }

    func searchEverywhere(
        at rootURL: URL,
        query: String,
        options: ProjectSearchOptions,
        visibilityRules: SearchVisibilityRules,
        includeGeneratedFileNames: Bool,
        kinds: Set<SearchResultKind>
    ) -> SearchEverywhereResults? {
        lock.withLock { self.kinds.append(kinds) }
        return fileResults(rootURL).map { SearchEverywhereResults(fileMatches: $0) }
    }

    func previewReplacement(
        at rootURL: URL,
        query: String,
        replacement: String,
        options: ProjectSearchOptions,
        paths: [String],
        textOverrides: [String: String],
        visibilityRules: SearchVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }

    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}
