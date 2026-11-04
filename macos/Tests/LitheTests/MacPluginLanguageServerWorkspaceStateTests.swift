import Foundation
@testable import Lithe
import LitheCoreContracts
import Testing

/// The per-workspace state of a plugin-owned language server (plan API-20):
/// what the host deletes to keep it bounded, and what it never touches. The
/// plugin is a Metals stub; Rust Core decides which directories expire.
struct MacPluginLanguageServerWorkspaceStateTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400

    // MARK: prune

    @Test
    func aWorkspaceNotUsedForLongerThanTheRetentionIsDeleted() throws {
        let fixture = try Fixture.make(retention: .init(maxEntries: 8, maxAgeDays: 30))
        defer { fixture.remove() }
        let stale = try fixture.makeState(for: "/work/stale", usedDaysAgo: 40)
        let recent = try fixture.makeState(for: "/work/recent", usedDaysAgo: 1)

        let removed = try fixture.state.prune(fixture.source, openWorkspaceURLs: [])

        #expect(removed == [stale.lastPathComponent])
        #expect(!fixture.exists(stale))
        #expect(fixture.exists(recent))
    }

    @Test
    func onlyTheNewestWorkspacesFitUnderTheEntryLimit() throws {
        let fixture = try Fixture.make(retention: .init(maxEntries: 2, maxAgeDays: 365))
        defer { fixture.remove() }
        let oldest = try fixture.makeState(for: "/work/a", usedDaysAgo: 3)
        let middle = try fixture.makeState(for: "/work/b", usedDaysAgo: 2)
        let newest = try fixture.makeState(for: "/work/c", usedDaysAgo: 1)

        try fixture.state.prune(fixture.source, openWorkspaceURLs: [])

        #expect(!fixture.exists(oldest))
        #expect(fixture.exists(middle))
        #expect(fixture.exists(newest))
    }

    @Test
    func anOpenWorkspaceIsNeverDeletedEvenWhenItIsTheOldest() throws {
        let fixture = try Fixture.make(retention: .init(maxEntries: 8, maxAgeDays: 30))
        defer { fixture.remove() }
        let open = try fixture.makeState(for: "/work/open", usedDaysAgo: 90)

        let removed = try fixture.state.prune(fixture.source, openWorkspaceURLs: [URL(fileURLWithPath: "/work/open")])

        #expect(removed.isEmpty)
        #expect(fixture.exists(open))
    }

    @Test
    func aPluginThatDeclaresNoRetentionKeepsEverything() throws {
        let fixture = try Fixture.make(retention: nil)
        defer { fixture.remove() }
        let old = try fixture.makeState(for: "/work/old", usedDaysAgo: 400)

        let removed = try fixture.state.prune(fixture.source, openWorkspaceURLs: [])

        #expect(removed.isEmpty)
        #expect(fixture.exists(old))
    }

    @Test
    func aFileOrALinkInTheStateAreaIsNotStateAndStaysPut() throws {
        let fixture = try Fixture.make(retention: .init(maxEntries: 8, maxAgeDays: 1))
        defer { fixture.remove() }
        let area = fixture.workspaceStates
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
        let file = area.appendingPathComponent("not-a-workspace.txt")
        try Data("x".utf8).write(to: file)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = area.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for url in [file, outside] {
            try FileManager.default.setAttributes(
                [.modificationDate: Self.now.addingTimeInterval(-100 * Self.day)], ofItemAtPath: url.path
            )
        }

        let removed = try fixture.state.prune(fixture.source, openWorkspaceURLs: [])

        #expect(removed.isEmpty)
        #expect(fixture.exists(file))
        #expect(fixture.exists(outside))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    @Test
    func anotherLanguagesStateIsNotPruned() throws {
        let fixture = try Fixture.make(retention: .init(maxEntries: 8, maxAgeDays: 30))
        defer { fixture.remove() }
        let other = try fixture.makeState(for: "/work/other", usedDaysAgo: 90, languageID: "kotlin")

        try fixture.state.prune(fixture.source, openWorkspaceURLs: [])

        #expect(fixture.exists(other))
    }

    // MARK: markUsed

    @Test
    func startingTheServerRefreshesWhenItsWorkspaceWasLastUsed() throws {
        let fixture = try Fixture.make(retention: .init(maxEntries: 8, maxAgeDays: 30))
        defer { fixture.remove() }
        let workspace = URL(fileURLWithPath: "/work/project")
        let directory = try fixture.makeState(for: workspace.path, usedDaysAgo: 90)

        try fixture.state.markUsed(fixture.source, workspaceRootURL: workspace)
        let removed = try fixture.state.prune(fixture.source, openWorkspaceURLs: [])

        #expect(removed.isEmpty)
        #expect(fixture.exists(directory))
    }

    @Test
    func markingAWorkspaceThatHasNoStateYetDoesNothing() throws {
        let fixture = try Fixture.make(retention: nil)
        defer { fixture.remove() }

        try fixture.state.markUsed(fixture.source, workspaceRootURL: URL(fileURLWithPath: "/work/new"))

        #expect(!FileManager.default.fileExists(atPath: fixture.workspaceStates.path))
    }

    // MARK: reset

    @Test
    func resettingDiscardsOnlyThatWorkspacesState() throws {
        let fixture = try Fixture.make(retention: nil)
        defer { fixture.remove() }
        let target = try fixture.makeState(for: "/work/target", usedDaysAgo: 1)
        let neighbour = try fixture.makeState(for: "/work/neighbour", usedDaysAgo: 1)

        try fixture.state.reset(fixture.source, workspaceRootURL: URL(fileURLWithPath: "/work/target"))

        #expect(!fixture.exists(target))
        #expect(fixture.exists(neighbour))
    }

    @Test
    func resettingAWorkspaceWithoutStateIsNotAnError() throws {
        let fixture = try Fixture.make(retention: nil)
        defer { fixture.remove() }

        try fixture.state.reset(fixture.source, workspaceRootURL: URL(fileURLWithPath: "/work/none"))
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let source: DeclarativeLanguageServerLaunchSource
        let directories: MacPluginStateDirectories
        let state: MacPluginLanguageServerWorkspaceState

        var workspaceStates: URL {
            directories.workspaceStatesDirectory(pluginID: source.pluginID, languageID: source.languageID)
        }

        static func make(retention: DeclarativeLanguageServer.StateRetention?) throws -> Fixture {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("lithe-workspace-state-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let operations = DeclarativePluginTestSupport.operations
            let manifest = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
                .appendingPathComponent("shared/contracts/plugins/v1/fixtures/language-server-backend-launch.plugin.json"))
            let descriptor = try operations.validate(manifest: manifest)
            let directories = MacPluginStateDirectories(
                rootURL: root.appendingPathComponent("state", isDirectory: true),
                temporaryRootURL: root.appendingPathComponent("scratch", isDirectory: true)
            )
            return Fixture(
                root: root,
                source: DeclarativeLanguageServerLaunchSource(
                    pluginID: descriptor.id.rawValue, languageID: "scala",
                    manifest: descriptor.normalizedManifest, packageURL: root.appendingPathComponent("package"),
                    resolvesLaunchWithBackend: true, stateRetention: retention
                ),
                directories: directories,
                state: MacPluginLanguageServerWorkspaceState(
                    directories: directories, planner: operations, now: { MacPluginLanguageServerWorkspaceStateTests.now }
                )
            )
        }

        /// The state a server of `languageID` wrote for the workspace at
        /// `path`, last used `days` ago.
        func makeState(for path: String, usedDaysAgo days: Double, languageID: String = "scala") throws -> URL {
            let directory = directories.workspaceStateDirectory(
                pluginID: source.pluginID, languageID: languageID, workspaceRootURL: URL(fileURLWithPath: path)
            )
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("index", isDirectory: true), withIntermediateDirectories: true
            )
            // Set last: writing into the directory would move its time.
            try FileManager.default.setAttributes(
                [.modificationDate: MacPluginLanguageServerWorkspaceStateTests.now.addingTimeInterval(-days * MacPluginLanguageServerWorkspaceStateTests.day)],
                ofItemAtPath: directory.path
            )
            return directory
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
