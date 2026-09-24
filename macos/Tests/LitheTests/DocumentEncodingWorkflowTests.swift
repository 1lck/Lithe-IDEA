import Foundation
import LitheCoreContracts
import LitheSearchModule
import Testing
@testable import Lithe

@MainActor
struct DocumentEncodingWorkflowTests {
    @Test func dismissingTheConfirmationAfterDiscardDoesNotCancelReopen() async throws {
        let operations = EncodingTestFileOperations()
        let feature = makeFeature(operations)
        defer { feature.reset() }
        let url = URL(fileURLWithPath: "/in-memory/encoding.txt")
        await feature.openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        let document = try #require(feature.activeDocument)
        document.applyLiveEditorText("local edit")

        let requestTask = try #require(feature.requestReopen(document, with: .gbk))
        await requestTask.value
        let request = try #require(feature.pendingEncodingReopen)
        let reopenTask = try #require(feature.resolvePendingEncodingReopen(saveChanges: false))
        // SwiftUI may dismiss the dialog after the button action has already
        // consumed the request. That dismissal must not cancel the new task.
        feature.dismissPendingEncodingReopen(request.id)
        await reopenTask.value

        #expect(document.text == "磁盘文本")
        #expect(document.encoding == .gbk)
        #expect(!document.isDirty)
    }

    @Test func anEditWhileReadingPreventsTheStaleEncodingSnapshotFromReplacingIt() async throws {
        let operations = EncodingTestFileOperations(blockSecondRead: true)
        let feature = makeFeature(operations)
        defer {
            operations.releaseSecondRead()
            feature.reset()
        }
        let url = URL(fileURLWithPath: "/in-memory/encoding-race.txt")
        await feature.openFileAsync(url, isReadOnly: false, displayPath: nil, activateWhenReady: true)
        let document = try #require(feature.activeDocument)
        let reopenTask = try #require(feature.requestReopen(document, with: .gbk))

        #expect(await operations.waitForSecondRead())
        document.applyLiveEditorText("new local edit")
        operations.releaseSecondRead()
        await reopenTask.value

        #expect(document.text == "new local edit")
        #expect(document.encoding == .utf8)
        #expect(document.isDirty)
    }

    private func makeFeature(_ operations: EncodingTestFileOperations) -> DocumentFeatureModel {
        let feature = DocumentFeatureModel(
            operations: EmptyEncodingWorkspaceOperations(),
            documentLifecycleDecider: RustDocumentLifecycleDecider(core: RustCoreBridge()),
            fileOperations: operations,
            fileStorage: UnavailableFileStorage(),
            binaryFileViewerRegistry: BinaryFileViewerRegistry()
        )
        feature.configure(
            workspaceURLProvider: { URL(fileURLWithPath: "/in-memory") },
            autoSaveEnabledProvider: { false },
            autoSaveDelayProvider: { 0 },
            notify: { _ in },
            onDocumentOpened: { _ in },
            onDocumentChanged: { _ in },
            onDocumentClosed: { _ in },
            onRecordSave: { _, _ in },
            onRecordDiscard: { _ in },
            onRecordExternalChanges: { _ in },
            onDocumentCollectionChanged: {},
            onProjectCloseReady: {}
        )
        return feature
    }
}

private struct EmptyEncodingWorkspaceOperations: WorkspaceOperations {
    func snapshot(at rootURL: URL, visibilityRules: FileVisibilityRules) -> WorkspaceSnapshot? { nil }
    func search(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: FileVisibilityRules) -> [FileSearchResult]? { nil }
    func searchEverywhere(at rootURL: URL, query: String, options: ProjectSearchOptions, visibilityRules: FileVisibilityRules) -> SearchEverywhereResults? { nil }
    func previewReplacement(at rootURL: URL, query: String, replacement: String, options: ProjectSearchOptions, paths: [String], textOverrides: [String: String], visibilityRules: FileVisibilityRules) -> [ProjectReplacementFile]? { nil }
    func readFile(at rootURL: URL, relativePath: String) -> String? { nil }
    func writeFile(_ text: String, at rootURL: URL, relativePath: String) -> Bool { false }
}

private final class EncodingTestFileOperations: WorkspaceFileOperations, @unchecked Sendable {
    let blockSecondRead: Bool
    private let lock = NSLock()
    private var readCount = 0
    private let secondReadStarted = TestGate()
    private let releaseGate = TestGate()

    init(blockSecondRead: Bool = false) { self.blockSecondRead = blockSecondRead }

    var supportsDocumentEncoding: Bool { true }

    func waitForSecondRead() async -> Bool { await secondReadStarted.waitUntilOpen() }
    func releaseSecondRead() { releaseGate.open() }

    func readDocumentDetails(from url: URL, encoding: DocumentEncoding?) throws -> DocumentReadDetails? {
        try details(for: nextRead())
    }

    func readDocumentDetailsAsync(from url: URL, encoding: DocumentEncoding?) async throws -> DocumentReadDetails? {
        let read = nextRead()
        if blockSecondRead && read == 2 {
            secondReadStarted.open()
            guard await releaseGate.waitUntilOpen() else { throw CancellationError() }
        }
        return try details(for: read)
    }

    func writeDocumentTextAsync(_ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding, expectedIdentity: String?) async throws -> EncodedDocumentWriteResult {
        .saved(identity: "saved-\(encoding.rawValue)")
    }

    func writeDocumentText(_ text: String, to url: URL, expectedContent: String?, encoding: DocumentEncoding, expectedIdentity: String?) throws -> EncodedDocumentWriteResult {
        .saved(identity: "saved-\(encoding.rawValue)")
    }

    private func nextRead() -> Int {
        lock.withLock {
            readCount += 1
            return readCount
        }
    }

    private func details(for read: Int) throws -> DocumentReadDetails {
        read == 1
            ? DocumentReadDetails(text: "initial", encoding: .utf8, identity: "utf8-initial")
            : DocumentReadDetails(text: "磁盘文本", encoding: .gbk, identity: "gbk-disk")
    }

    func fileExists(at url: URL) -> Bool { true }
    func isDirectory(at url: URL) -> Bool { false }
    func createFile(at url: URL) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func removeItem(at url: URL) throws {}
    func trashItem(at url: URL) throws {}
    func writeText(_ text: String, to url: URL) throws {}
    func readText(from url: URL) throws -> String { "" }
}
