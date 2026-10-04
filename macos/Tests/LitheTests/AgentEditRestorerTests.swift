import Foundation
import Testing
@testable import Lithe
@testable import LitheAgentConversationModule

struct AgentEditRestorerTests {
    @MainActor @Test func pendingEditorInputIsDrainedBeforeRejectingADirtyBuffer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.txt")
        try Data("after".utf8).write(to: url)
        let store = AgentReviewTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services
        let model = AppModel(settings: settings, services: services)
        model.workspaceSessionCoordinator.beginWorkspace(at: root)
        await model.documentFeature.openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        do {
            let document = try #require(model.documentFeature.editorDocuments.first)
            var drained = false
            document.synchronizeEditor = { completion in
                drained = true
                document.applyLiveEditorText("user draft")
                completion(.success(()))
            }
            defer { document.synchronizeEditor = nil }
            await #expect(throws: AgentEditRestoreError.self) { try await model.restoreAgentFile(change([("before", "after")])) }
            #expect(drained)
            #expect(document.text == "user draft")
            #expect(try String(contentsOf: url, encoding: .utf8) == "after")
            await model.shutdownProjectSession()
        } catch {
            await model.shutdownProjectSession()
            throw error
        }
    }

    @Test func restoresChainedEditsAndPreservesTheExistingBOM() async throws {
        try await withWorkspace { workspace, files in
            let url = workspace.appendingPathComponent("a.txt")
            try Data([0xef, 0xbb, 0xbf] + Array("C\n".utf8)).write(to: url)
            let change = change([("A\n", "B\n"), ("B\n", "C\n")])
            try await MacAgentEditRestorer(fileOperations: files).restore(change, in: workspace)
            #expect(try Data(contentsOf: url) == Data([0xef, 0xbb, 0xbf] + Array("A\n".utf8)))
        }
    }

    @Test func reversesUniqueExcerptsWithoutRemovingUnrelatedText() async throws {
        try await withWorkspace { workspace, files in
            let url = workspace.appendingPathComponent("a.txt")
            try Data("prefix\nnew line\nsuffix\n".utf8).write(to: url)
            try await MacAgentEditRestorer(fileOperations: files).restore(change([("old line", "new line")]), in: workspace)
            #expect(try String(contentsOf: url, encoding: .utf8) == "prefix\nold line\nsuffix\n")
        }
    }

    @Test func missingAmbiguousAndOverlappingMatchesNeverWrite() async throws {
        try await withWorkspace { workspace, files in
            let url = workspace.appendingPathComponent("a.txt")
            for (disk, reported) in [("user changed it", "after"), ("after\nafter", "after"), ("aaa", "aa")] {
                let bytes = Data(disk.utf8)
                try bytes.write(to: url)
                await #expect(throws: AgentEditRestoreError.self) {
                    try await MacAgentEditRestorer(fileOperations: files).restore(change([("before", reported)]), in: workspace)
                }
                #expect(try Data(contentsOf: url) == bytes)
            }
        }
    }

    @Test func deletionRequiresThePathToRemainAbsent() async throws {
        try await withWorkspace { workspace, files in
            let url = workspace.appendingPathComponent("a.txt")
            var deleted = change([("original", "")])
            deleted.isDeletion = true
            try await MacAgentEditRestorer(fileOperations: files).restore(deleted, in: workspace)
            #expect(try String(contentsOf: url, encoding: .utf8) == "original")
            try Data("new user file".utf8).write(to: url)
            await #expect(throws: AgentEditRestoreError.self) {
                try await MacAgentEditRestorer(fileOperations: files).restore(deleted, in: workspace)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "new user file")
        }
    }

    @Test func unknownOriginalAndTruncatedEvidenceCannotRemoveOrOverwriteFiles() async throws {
        try await withWorkspace { workspace, files in
            let url = workspace.appendingPathComponent("a.txt")
            try Data("after".utf8).write(to: url)
            var incomplete = change([("before", "after")])
            incomplete.diffs[0].oldText = nil
            await #expect(throws: AgentEditRestoreError.self) {
                try await MacAgentEditRestorer(fileOperations: files).restore(incomplete, in: workspace)
            }
            incomplete.diffs[0].oldText = "before"
            incomplete.diffs[0].isTruncated = true
            await #expect(throws: AgentEditRestoreError.self) {
                try await MacAgentEditRestorer(fileOperations: files).restore(incomplete, in: workspace)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "after")
        }
    }

    @Test func workspaceTraversalAndSymlinkEscapesAreRejected() async throws {
        try await withWorkspace { workspace, files in
            let outside = workspace.appendingPathComponent("outside")
            let root = workspace.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let target = outside.appendingPathComponent("a.txt")
            try Data("after".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
            for path in ["../outside/a.txt", "link/a.txt", target.path] {
                var escaping = change([("before", "after")], path: path)
                escaping.diffs[0].path = path
                await #expect(throws: AgentEditRestoreError.self) {
                    try await MacAgentEditRestorer(fileOperations: files).restore(escaping, in: root)
                }
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "after")
        }
    }

    @Test func explicitCreationUsesRecoverableRemovalAndRefusesChangedContent() async throws {
        try await withWorkspace { workspace, files in
            let url = workspace.appendingPathComponent("a.txt")
            let recovered = workspace.appendingPathComponent("recovered.txt")
            var created = change([("", "created")])
            created.diffs[0].oldText = nil
            created.diffs[0].operation = "add"
            let adapter = ReviewFileOperations(native: files, recovered: recovered)
            try Data("user modified".utf8).write(to: url)
            await #expect(throws: AgentEditRestoreError.self) {
                try await MacAgentEditRestorer(fileOperations: adapter).restore(created, in: workspace)
            }
            #expect(!files.fileExists(at: recovered))
            try Data("created".utf8).write(to: url)
            try await MacAgentEditRestorer(fileOperations: adapter).restore(created, in: workspace)
            #expect(!files.fileExists(at: url))
            #expect(try String(contentsOf: recovered, encoding: .utf8) == "created")
        }
    }

    @Test func aConcurrentWriteBetweenReadAndCommitIsPreserved() async throws {
        try await withWorkspace { workspace, files in
            let url = workspace.appendingPathComponent("a.txt")
            try Data("after".utf8).write(to: url)
            let adapter = ReviewFileOperations(native: files, recovered: workspace.appendingPathComponent("recovered.txt"),
                concurrentText: "another writer")
            await #expect(throws: AgentEditRestoreError.self) {
                try await MacAgentEditRestorer(fileOperations: adapter).restore(change([("before", "after")]), in: workspace)
            }
            #expect(try String(contentsOf: url, encoding: .utf8) == "another writer")
        }
    }

    private func change(_ versions: [(String, String)], path: String = "a.txt") -> AgentFileChange {
        var result = AgentFileChange(path: path)
        result.diffs = versions.map { .init(path: path, oldText: $0.0, newText: $0.1, isTruncated: false) }
        return result
    }

    private func withWorkspace(_ run: (URL, MacWorkspaceFileOperations) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await run(root, MacWorkspaceFileOperations())
    }
}

/// Real guarded writes; replace Trash only to keep the user's Trash untouched.
/// The optional concurrent write deterministically occurs after the snapshot.
private struct ReviewFileOperations: WorkspaceFileOperations {
    let native: MacWorkspaceFileOperations
    let recovered: URL
    var concurrentText: String?
    func fileExists(at url: URL) -> Bool { native.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { native.isDirectory(at: url) }
    func createFile(at url: URL) throws { try native.createFile(at: url) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try native.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws { try native.copyItem(at: sourceURL, to: destinationURL) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try native.moveItem(at: sourceURL, to: destinationURL) }
    func removeItem(at url: URL) throws { try native.removeItem(at: url) }
    func trashItem(at url: URL) throws { try native.moveItem(at: url, to: recovered) }
    func writeText(_ text: String, to url: URL) throws { try native.writeText(text, to: url) }
    func readText(from url: URL) throws -> String { try native.readText(from: url) }
    func readDocumentDetails(from url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails? {
        try native.readDocumentDetails(from: url, encoding: encoding)
    }
    func writeDocumentText(_ text: String, to url: URL, expectedContent: String?,
                           encoding: DocumentEncoding, expectedIdentity: String?) throws -> EncodedDocumentWriteResult {
        if let concurrentText { try Data(concurrentText.utf8).write(to: url) }
        return try native.writeDocumentText(text, to: url, expectedContent: expectedContent,
            encoding: encoding, expectedIdentity: expectedIdentity)
    }
}

private final class AgentReviewTestStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { lock.withLock { values[key] as? Data } }
    func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    func stringArray(forKey key: String) -> [String]? { lock.withLock { values[key] as? [String] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
}
