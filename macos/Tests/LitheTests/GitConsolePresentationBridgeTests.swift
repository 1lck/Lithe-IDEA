import AppKit
import Foundation
import SwiftUI
import Testing
import LitheCoreContracts
@testable import LitheGitModule
@testable import Lithe

@Suite("Git console Core presentation bridge")
struct GitConsolePresentationBridgeTests {
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func worktreeActionsUseTheProjectConsoleAcrossCheckoutChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-console-worktrees-\(UUID().uuidString)")
        let original = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = original.resolvingSymlinksInPath()
        let linked = root.deletingLastPathComponent().appendingPathComponent("linked checkout")
        for arguments in [["init", "--template=", "-q", "--initial-branch=console-base"],
                          ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false", "commit", "-qm", "initial", "--allow-empty"]] {
            let result = try await TestProcess.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"), arguments: arguments, currentDirectoryURL: root)
            try #require(result.terminationStatus == 0)
        }
        let journal = GitExecutionJournal()
        let core = RustCoreBridge(gitExecutionJournal: journal)
        try #require(core.isAvailable)
        let service = GitService(operations: RustGitOperations(core: core))
        let feature = GitFeatureModel(service: service, executionJournal: journal)
        let linkedFeature = GitFeatureModel(service: service, executionJournal: journal)
        defer { feature.reset(); linkedFeature.reset() }
        feature.configure(workspaceURLProvider: { root }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await feature.refreshGit()
        let error = await feature.createWorktree(GitWorktreeCreation(mode: .detached, name: nil, reference: nil,
            revision: "HEAD", destination: linked, noCheckout: false))
        try #require(error == nil)
        let worktree = try #require(feature.gitWorktrees.first { $0.url.standardizedFileURL.path == linked.standardizedFileURL.path })
        #expect(journal.snapshot.contains { $0.arguments.contains("worktree") && $0.arguments.contains("add") })

        // Another checkout's feature reads the same project history, without
        // relying on a selected-repository filter or an open Console view.
        linkedFeature.configure(workspaceURLProvider: { linked }, isGitLogVisibleProvider: { false }, notify: { _ in }, onStateRefreshed: {})
        await linkedFeature.refreshGit()
        let linkedRepositoryRoot = try #require(linkedFeature.gitRepositoryRoot)
        await linkedFeature.loadGitConsoleIfNeeded()
        #expect(linkedFeature.gitConsoleEntries.contains { $0.workingDirectory.resolvingSymlinksInPath().path == root.path && $0.arguments.contains("add") })
        await linkedFeature.repairWorktrees()
        let repairEntry = try #require(journal.snapshot.first { $0.arguments.contains("worktree") && $0.arguments.contains("repair") })
        #expect(repairEntry.workingDirectory.resolvingSymlinksInPath().path == linkedRepositoryRoot.resolvingSymlinksInPath().path)
        await feature.setWorktreeLocked(worktree, locked: true)
        await feature.setWorktreeLocked(worktree, locked: false)
        await feature.pruneWorktrees()
        await feature.removeWorktree(worktree, force: false)
        await feature.loadGitConsoleIfNeeded()
        let actions = feature.gitConsoleEntries.map { Array($0.arguments.drop { $0 != "worktree" }.prefix(2)) }
        for action in ["add", "repair", "lock", "unlock", "prune", "remove"] {
            #expect(actions.contains(["worktree", action]))
        }
        #expect(feature.gitConsoleEntries.contains { $0.id == repairEntry.id })
        #expect(feature.gitConsoleEntries.allSatisfy { $0.arguments.contains("worktree") || $0.arguments.contains("version") }, "Internal refresh queries must remain silent: \(feature.gitConsoleEntries.map(\.arguments))")
        #expect(Set(feature.gitConsoleEntries.map(\.id)).count == feature.gitConsoleEntries.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func purePresentationMatchesEverySharedFixtureWithoutRecordingItself() throws {
        struct Sample: Decodable { let input: ToolingJSONValue; let presentation: GitConsolePresentation }
        struct Fixture: Decodable { let cases: [Sample] }
        let journal = GitExecutionJournal()
        let core = RustCoreBridge(gitExecutionJournal: journal)
        try #require(core.isAvailable, "The integration lane must link Rust Core")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            repositoryRoot.appendingPathComponent("shared/fixtures/git/console-presentation-v1.json")))
        for sample in fixture.cases {
            let result: Result<GitConsolePresentation?, RustCoreBridge.CoreCallError> = core.executeNullableResult(
                command: "git.consolePresentation", payload: sample.input)
            #expect(try result.get() == sample.presentation)
        }
        #expect(journal.snapshot.isEmpty)
    }

    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LITHE_RUN_GIT_EXECUTION_INTEGRATION"] == "1"))
    func nativeConsoleRendersCoreDisclosuresInContinuousText() throws {
        let core = RustCoreBridge()
        try #require(core.isAvailable)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let root = URL(fileURLWithPath: "/workspace/console-example")
        let entries = [
            GitConsoleEntry(timestamp: date, workingDirectory: root,
                arguments: ["fetch", "origin", "--prune"], output: "remote: Counting objects: 100% (8/8), done.\nremote: Compressing objects: 100% (4/4), done.\nFrom https://example.invalid/repository\nAlready up to date.\n", exitCode: 0,
                temporaryConfig: [["color.ui", "false"], ["core.quotepath", "false"]]),
            GitConsoleEntry(timestamp: date, workingDirectory: root,
                arguments: ["worktree", "add", "--detach", "--", "/workspace/review-checkout", "HEAD"], output: "Preparing worktree (detached HEAD abcd123)\nHEAD is now at abcd123 initial commit\n", exitCode: 0),
            GitConsoleEntry(timestamp: date, workingDirectory: root,
                arguments: ["commit", "--amend", "-m", "First line\nMore details in the commit message"], output: "", exitCode: 0),
            GitConsoleEntry(timestamp: date, workingDirectory: root,
                arguments: ["fetch", "origin", "--prune"], output: "", exitCode: 0,
                remoteResult: .init(remote: "origin", succeeded: true, updatedReferences: [], deletedReferences: [])),
        ]
        let request = GitConsolePresentationRequest(entries: entries, search: "Counting")
        let presentation = try #require(RustGitOperations(core: core).consolePresentation(request))
        let view = VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                GitConsoleEntryView(entry: entry, wrapsLines: true, presentation: presentation.entries[index], expanded: .constant([]))
            }
        }
        .padding(16).frame(width: 1200, height: 520, alignment: .topLeading).background(Color.white)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 520)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = repositoryRoot.appendingPathComponent(".artifacts/issue438")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("console-compression-macos.png"))
        #expect(presentation.entries[0].command.contains { $0.kind == "configuration" })
        #expect(presentation.entries[0].output.contains { $0.kind == "progress" && $0.matches == 1 })
        #expect(presentation.entries[1].output.allSatisfy { $0.kind == "text" })
        #expect(presentation.entries[2].command.contains { $0.kind == "text" && $0.text == "--amend" })
        #expect(presentation.entries[2].command.contains { $0.kind == "text" && $0.text.contains("\n") })
        #expect(presentation.entries[2].notice == "completedWithoutOutput")
        #expect(presentation.entries[3].notice == "fetchUnchanged")
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }
}
