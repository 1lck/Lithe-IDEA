import Foundation
import Testing
@testable import Lithe

@Suite("Language workspace edit service")
@MainActor
struct LanguageWorkspaceEditServiceTests {
    @Test("rejects edits outside the workspace")
    func rejectsOutsideWorkspace() {
        let outsideURL = URL(fileURLWithPath: "/other/Outside.java")
        let edit = LanguageServerWorkspaceEdit(changes: [
            outsideURL: [replacement(in: outsideURL)]
        ])
        let fileOperations = InMemoryWorkspaceFileOperations(
            files: [outsideURL: "before"]
        )
        var messages: [String] = []

        let applied = LanguageWorkspaceEditService(
            notify: { messages.append($0) }
        ).apply(
            edit,
            workspaceURL: URL(fileURLWithPath: "/workspace"),
            openDocuments: [],
            fileOperations: fileOperations,
            updateDocument: { _, _ in Issue.record("unexpected document update") }
        )

        #expect(!applied)
        #expect(fileOperations.files[outsideURL] == "before")
        #expect(messages == ["Could not apply language edit: Language edit targets a file outside the workspace."])
    }

    @Test("rejects edits to read-only open documents")
    func rejectsReadOnlyDocument() {
        let url = URL(fileURLWithPath: "/workspace/ReadOnly.java")
        let document = EditorDocument(
            url: url,
            text: "before",
            modificationDate: nil,
            isReadOnly: true
        )
        let edit = LanguageServerWorkspaceEdit(changes: [
            url: [replacement(in: url)]
        ])
        var messages: [String] = []

        let applied = LanguageWorkspaceEditService(
            notify: { messages.append($0) }
        ).apply(
            edit,
            workspaceURL: URL(fileURLWithPath: "/workspace"),
            openDocuments: [document],
            fileOperations: InMemoryWorkspaceFileOperations(),
            updateDocument: { _, _ in Issue.record("unexpected document update") }
        )

        #expect(!applied)
        #expect(document.text == "before")
        #expect(messages == ["Could not apply language edit: This document is read-only"])
    }

    @Test("rolls back files written before a later write fails")
    func rollsBackPartialWrite() {
        let firstURL = URL(fileURLWithPath: "/workspace/First.java")
        let secondURL = URL(fileURLWithPath: "/workspace/Second.java")
        let edit = LanguageServerWorkspaceEdit(changes: [
            firstURL: [replacement(in: firstURL)],
            secondURL: [replacement(in: secondURL)]
        ])
        let fileOperations = InMemoryWorkspaceFileOperations(
            files: [firstURL: "before", secondURL: "before"],
            failingWriteNumber: 2
        )
        var messages: [String] = []

        let applied = LanguageWorkspaceEditService(
            notify: { messages.append($0) }
        ).apply(
            edit,
            workspaceURL: URL(fileURLWithPath: "/workspace"),
            openDocuments: [],
            fileOperations: fileOperations,
            updateDocument: { _, _ in Issue.record("unexpected document update") }
        )

        #expect(!applied)
        #expect(fileOperations.files[firstURL] == "before")
        #expect(fileOperations.files[secondURL] == "before")
        let writes = fileOperations.writes
        #expect(writes.count == 4)
        #expect(writes.first?.text != "before")
        #expect(writes.first?.succeeded == true)
        #expect(writes.dropFirst().first?.succeeded == false)
        #expect(writes.suffix(2).allSatisfy { $0.text == "before" && $0.succeeded })
        #expect(messages == ["Could not apply language edit: \(CocoaError(.fileWriteUnknown).localizedDescription)"])
    }

    private func replacement(in url: URL) -> LanguageServerTextEdit {
        LanguageServerTextEdit(
            range: LanguageServerRange(
                start: LanguageServerPosition(line: 0, utf16Column: 0),
                end: LanguageServerPosition(line: 0, utf16Column: 6)
            ),
            newText: url.lastPathComponent
        )
    }
}

private final class InMemoryWorkspaceFileOperations: WorkspaceFileOperations, @unchecked Sendable {
    struct Write {
        let url: URL
        let text: String
        let succeeded: Bool
    }

    private let lock = NSLock()
    private var storedFiles: [URL: String]
    private var recordedWrites: [Write] = []
    private let failingWriteNumber: Int?

    init(files: [URL: String] = [:], failingWriteNumber: Int? = nil) {
        self.storedFiles = files
        self.failingWriteNumber = failingWriteNumber
    }

    var files: [URL: String] { lock.withLock { storedFiles } }
    var writes: [Write] { lock.withLock { recordedWrites } }

    func fileExists(at url: URL) -> Bool {
        lock.withLock { storedFiles[url.standardizedFileURL] != nil }
    }

    func isDirectory(at url: URL) -> Bool { false }
    func createFile(at url: URL) throws {}
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {}
    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {}
    func removeItem(at url: URL) throws {}
    func trashItem(at url: URL) throws {}

    func writeText(_ text: String, to url: URL) throws {
        try lock.withLock {
            let shouldFail = recordedWrites.count + 1 == failingWriteNumber
            recordedWrites.append(Write(url: url, text: text, succeeded: !shouldFail))
            if shouldFail { throw CocoaError(.fileWriteUnknown) }
            storedFiles[url.standardizedFileURL] = text
        }
    }

    func readText(from url: URL) throws -> String {
        guard let text = lock.withLock({ storedFiles[url.standardizedFileURL] }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return text
    }
}
