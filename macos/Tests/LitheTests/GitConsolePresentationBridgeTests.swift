import AppKit
import Foundation
import SwiftUI
import Testing
import LitheCoreContracts
import LitheGitModule
@testable import Lithe

@Suite("Git console Core presentation bridge")
struct GitConsolePresentationBridgeTests {
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
                arguments: ["fetch", "origin", "--prune"], output: "From https://example.invalid/repository\nAlready up to date.\n", exitCode: 0,
                temporaryConfig: [["color.ui", "false"], ["core.quotepath", "false"]]),
            GitConsoleEntry(timestamp: date, workingDirectory: root,
                arguments: ["reflog"], output: (0..<16).map { "abcd123 HEAD@{\($0)}: commit: change \($0)\n" }.joined(), exitCode: 0),
            GitConsoleEntry(timestamp: date, workingDirectory: root,
                arguments: ["commit", "--amend", "-m", "First line\nMore details in the commit message"], output: "", exitCode: 0),
        ]
        let request = GitConsolePresentationRequest(entries: entries, search: "change 8")
        let presentation = try #require(RustGitOperations(core: core).consolePresentation(request))
        let view = VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                GitConsoleEntryView(entry: entry, wrapsLines: true, presentation: presentation.entries[index], expanded: .constant([]))
            }
        }
        .padding(16).frame(width: 1200, height: 420, alignment: .topLeading).background(Color.white)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1200, height: 420)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = repositoryRoot.appendingPathComponent(".artifacts/issue438")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("console-compression-macos.png"))
        #expect(presentation.entries[0].command.contains { $0.kind == "configuration" })
        #expect(presentation.entries[1].output.contains { $0.kind == "commits" && $0.matches == 1 })
        #expect(presentation.entries[2].command.contains { $0.kind == "text" && $0.text == "--amend" })
        #expect(presentation.entries[2].command.contains { $0.kind == "argument" && $0.text.contains("\n") })
    }

    private var repositoryRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }
}
