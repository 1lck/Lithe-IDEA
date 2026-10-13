import Foundation
import Testing
@testable import Lithe

/// Drives project tree batch actions through the production app model, service
/// container, Rust workspace scan and native file manager on a temporary project.
/// Successful Trash moves stay in unit tests so this suite never touches ~/.Trash.
@Suite("Project tree batch file workflow", .serialized)
@MainActor
struct ProjectTreeBatchFileWorkflowTests {
    @Test
    func copyPasteDuplicateAndTrashUseRealFilesAndKeepUnsavedEdits() async throws {
        let fixture = try BatchFileFixture()
        defer { fixture.remove() }
        let clipboard = BatchFileClipboardUI()
        let model = fixture.makeAppModel(platformUI: clipboard)
        defer { model.workspaceFeature.reset() }
        model.openProjectDirectly(fixture.root)
        #expect(await awaitChange(on: model) { fixture.treeContains(model, "b.txt") })

        // ⌘C writes both files; ⌘V into a folder holding a.txt keeps it and adds a copy.
        model.copyProjectItems([fixture.url("a.txt"), fixture.url("b.txt")])
        #expect(clipboard.files == [fixture.url("a.txt"), fixture.url("b.txt")])
        await model.pasteProjectItems(in: fixture.url("dest"))
        #expect(try fixture.text("dest/a.txt") == "existing")
        #expect(try fixture.text("dest/a copy.txt") == "alpha")
        #expect(try fixture.text("dest/b.txt") == "beta")
        #expect(await awaitChange(on: model) { fixture.treeContains(model, "dest/a copy.txt") })

        // Duplicate keeps each copy next to its own source.
        await model.duplicateProjectItems([fixture.url("a.txt"), fixture.url("dest/b.txt")])
        #expect(try fixture.text("a copy.txt") == "alpha")
        #expect(try fixture.text("dest/b copy.txt") == "beta")

        // Pasting a folder into its own child is rejected without copying.
        model.copyProjectItems([fixture.url("dest")])
        await model.pasteProjectItems(in: fixture.url("dest"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("dest/dest").path))

        // An edit made after the dialog opened keeps its file and editor tab.
        // Only that file is requested so the test never writes to the user's Trash.
        model.openFile(fixture.url("b.txt"))
        #expect(await awaitChange(on: model) { model.openDocuments.contains { $0.url == fixture.url("b.txt") } })
        let edited = try #require(model.openDocuments.first { $0.url == fixture.url("b.txt") })
        model.requestDeleteProjectItems([fixture.url("b.txt"), fixture.root])
        let request = try #require(model.pendingProjectItemDeletion)
        #expect(request.url == fixture.url("b.txt") && request.additionalItems.isEmpty)
        model.cancelProjectItemDeletion()
        edited.text = "unsaved"
        await model.confirmProjectItemDeletion(request)
        #expect(try fixture.text("b.txt") == "beta")
        #expect(model.openDocuments.contains { $0 === edited })
        #expect(edited.text == "unsaved")
        #expect(model.notifications.contains { $0.message == "Save or discard unsaved files before deleting this item" })
    }
    @Test
    func moveBatchTreatsFoldersAtomicallyAndRelocatesOpenDocumentsAndMarks() async throws {
        let fixture = try BatchFileFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("bucket"), withIntermediateDirectories: true)
        let model = fixture.makeAppModel(platformUI: BatchFileClipboardUI())
        defer { model.workspaceFeature.reset() }
        model.openProjectDirectly(fixture.root)
        #expect(await awaitChange(on: model) { fixture.treeContains(model, "dest/a.txt") })
        model.openFile(fixture.url("dest/a.txt"))
        #expect(await awaitChange(on: model) { model.openDocuments.contains { $0.url == fixture.url("dest/a.txt") } })
        let document = try #require(model.openDocuments.first { $0.url == fixture.url("dest/a.txt") })
        await model.markProjectDirectory(fixture.url("dest"), as: .resources)

        // A selected folder and its selected child must produce one directory move.
        await model.moveProjectItems([fixture.url("b.txt"), fixture.url("dest/a.txt"), fixture.url("dest")], to: fixture.url("bucket"))
        #expect(try fixture.text("bucket/b.txt") == "beta")
        #expect(try fixture.text("bucket/dest/a.txt") == "existing")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("dest").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.url("b.txt").path))
        #expect(document.url == fixture.url("bucket/dest/a.txt"))
        #expect(document.text == "existing")
        #expect(model.projectDirectoryMarks["bucket/dest"] == .resources)
        #expect(model.projectDirectoryMarks["dest"] == nil)
        #expect(await awaitChange(on: model) { fixture.treeContains(model, "bucket/dest/a.txt") })
    }

    @Test
    func moveRejectsSelfDescendantsRootAndSymlinkEscapesWithoutChangingFiles() async throws {
        let fixture = try BatchFileFixture()
        defer { fixture.remove() }
        let outside = try BatchFileFixture()
        defer { outside.remove() }
        try FileManager.default.createSymbolicLink(at: fixture.url("escape"), withDestinationURL: outside.root)
        try FileManager.default.createSymbolicLink(at: fixture.url("dest/alias"), withDestinationURL: fixture.url("dest"))
        let model = fixture.makeAppModel(platformUI: BatchFileClipboardUI())
        defer { model.workspaceFeature.reset() }
        model.openProjectDirectly(fixture.root)
        #expect(await awaitChange(on: model) { fixture.treeContains(model, "b.txt") })

        await model.moveProjectItems([fixture.url("dest")], to: fixture.url("dest"))
        await model.moveProjectItems([fixture.url("dest")], to: fixture.url("dest/alias"))
        await model.moveProjectItems([fixture.root, fixture.url("b.txt")], to: fixture.url("dest"))
        await model.moveProjectItems([fixture.url("b.txt")], to: fixture.url("escape"))
        await model.moveProjectItems([fixture.url("escape/b.txt")], to: fixture.url("dest"))
        await model.moveProjectItems([fixture.url("a.txt"), fixture.url("b.txt")], to: fixture.url("dest"))
        #expect(try fixture.text("a.txt") == "alpha")
        #expect(try fixture.text("b.txt") == "beta")
        #expect(try fixture.text("dest/a.txt") == "existing")
        #expect(try outside.text("b.txt") == "beta")
        #expect(!FileManager.default.fileExists(atPath: fixture.url("dest/b.txt").path))
    }

}

@MainActor
private final class BatchFileClipboardUI: PlatformUI {
    private(set) var files: [URL] = []

    func copyFilesToClipboard(_ urls: [URL]) -> Bool {
        files = urls
        return !urls.isEmpty
    }
    func fileURLsFromClipboard() -> [URL] { files }
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

@MainActor
private struct BatchFileFixture {
    let root: URL

    init() throws {
        // `target` is hidden by the default build-output rules, so use `dest`.
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-batch-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        root = created.standardizedFileURL
        try FileManager.default.createDirectory(at: url("dest"), withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: url("a.txt"))
        try Data("beta".utf8).write(to: url("b.txt"))
        try Data("existing".utf8).write(to: url("dest/a.txt"))
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }
    func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func treeContains(_ model: AppModel, _ path: String) -> Bool {
        func contains(_ node: FileNode) -> Bool {
            node.url.standardizedFileURL == url(path) || (node.children ?? []).contains(where: contains)
        }
        return model.rootNode.map(contains) == true
    }

    func makeAppModel(platformUI: any PlatformUI) -> AppModel {
        let store = BatchFileTestStore()
        let settings = AppSettings(store: store)
        let services = MacServiceContainer(
            store: store, settings: settings, moduleLaunchMode: .safeMode, platformUI: platformUI
        ).services
        return AppModel(settings: settings, services: services)
    }
}

private final class BatchFileTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
