import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Lithe

struct RecentProjectBranchMetadataTests {
    @MainActor
    @Test(arguments: [ColorScheme.dark, .light])
    func welcomeRowsGrowForBranchesWithoutOverlapping(scheme: ColorScheme) async throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let branched = root.appendingPathComponent("AlphaProject")
        let folder = root.appendingPathComponent("BetaFolder")
        for url in [branched, folder] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let store = BranchMetadataKeyValueStore()
        let projects = RecentProjectsStore(store: store)
        _ = projects.record(branched, branch: "codex/layout", in: projects.record(folder, in: []))
        let settings = AppSettings(store: store)
        let container = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode)
        defer { container.moduleLifecycleCoordinator.stop() }
        let model = AppModel(settings: settings, services: container.services)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: WelcomeView()
            .environmentObject(model).environmentObject(UpdateChecker(preferences: defaults))
            .environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await WorkbenchTestScope.withCleanup({ await model.shutdownProjectSession() }) { _ in
            for width: CGFloat in [800, 1100, 800] {
                window.setContentSize(NSSize(width: width, height: 650))
                let search = try await AgentNativeControlTestSupport.frame(of: "welcome-project-search", in: host)
                let actions = try await AgentNativeControlTestSupport.frame(
                    of: width == 800 ? "welcome-more-actions" : "welcome-secondary-actions", in: host)
                // Accessibility excludes the shared search chrome's 3pt insets on both sides.
                #expect(search.width >= 180 - 6)
                #expect(!search.intersects(actions))
                #expect(abs(search.midY - actions.midY) <= 1)
                #expect(host.bounds.contains(search) && host.bounds.contains(actions))
                let threeLines = try await AgentNativeControlTestSupport.frame(of: "welcome-project-" + branched.path, in: host)
                let twoLines = try await AgentNativeControlTestSupport.frame(of: "welcome-project-" + folder.path, in: host)
                #expect(!threeLines.intersects(twoLines))
                // A native 16pt branch icon plus VerticalLayout(4), not a fixed 56pt row.
                #expect(abs(threeLines.height - twoLines.height - 20) <= 1)
                #expect(threeLines.minX == twoLines.minX && threeLines.width == twoLines.width)
                if let directory = ProcessInfo.processInfo.environment["LITHE_WELCOME_LAYOUT_SCREENSHOTS"] {
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = try #require(bitmap.representation(using: .png, properties: [:]))
                    try image.write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("welcome-\(scheme == .dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
        }
    }

    @Test
    func welcomeBranchUsesTheMappedIdeaVcsIconAtItsNativeSize() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("macos/Sources/Lithe/Views/App/WelcomeView.swift"), encoding: .utf8)
        #expect(source.contains("resourcePath: \"expui/general/vcs.svg\",\n                                    size: 16"))
        #expect(!source.contains("resourcePath: \"vcs/branch.svg\""))
        for name in ["vcs.svg", "vcs_dark.svg"] {
            let icon = try String(contentsOf: root.appendingPathComponent("macos/Resources/IDEAIcons/expui/general/" + name), encoding: .utf8)
            #expect(icon.contains("viewBox=\"0 0 16 16\""))
            #expect(icon.contains("<circle") && !icon.contains("<rect"))
        }
    }

    @Test
    func readsTheCheckedOutBranchFromHEADWithoutGit() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try write("ref: refs/heads/feat/1316-settings-info-tips\n", to: workspace.appendingPathComponent(".git/HEAD"))

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == "feat/1316-settings-info-tips")
    }

    @Test
    func readsTheBranchThroughAWorktreeGitPointer() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("checkout")
        let gitDirectory = root.appendingPathComponent("repository/.git/worktrees/checkout")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try write("gitdir: ../repository/.git/worktrees/checkout\n", to: workspace.appendingPathComponent(".git"))
        try write("ref: refs/heads/fix/worktree\n", to: gitDirectory.appendingPathComponent("HEAD"))

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == "fix/worktree")
    }

    @Test
    func detachedHEADUsesTheShortCommitID() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try write("0123456789abcdef0123456789abcdef01234567\n", to: workspace.appendingPathComponent(".git/HEAD"))

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == "01234567")
    }

    @Test
    func foldersWithoutARepositoryHaveNoBranch() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let reader = MacRecentProjectBranchReader(storage: MacFileStorage())
        #expect(reader.branch(forProjectAt: workspace) == nil)
    }

    @Test
    func recordedBranchIsPersistedAndClearedForFolders() {
        let store = BranchMetadataKeyValueStore()
        let projects = RecentProjectsStore(store: store)
        let repository = URL(fileURLWithPath: "/tmp/lithe-branch-metadata")
        var recorded = projects.record(repository, branch: "feat/metadata", in: [])
        #expect(recorded.first?.branch == "feat/metadata")

        // Reopening a folder that is no longer a repository must not keep the
        // previous branch in the persisted list.
        recorded = projects.record(repository, branch: nil, in: recorded)
        #expect(recorded.first?.branch == nil)
        #expect(projects.load().first?.branch == nil)
    }

    private func makeWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-welcome-branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}

private final class BranchMetadataKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
