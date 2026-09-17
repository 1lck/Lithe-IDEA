import Foundation
import Testing
@testable import Lithe

@MainActor
@Suite("Remote editor document synchronization")
struct EditorDocumentSynchronizationTests {
    private func document() -> EditorDocument {
        EditorDocument(url: URL(fileURLWithPath: "/in-memory/Probe.java"), text: "class Probe {}", modificationDate: nil)
    }

    @Test func nativeDocumentActionsRemainSynchronous() {
        let document = document()
        var completed = false
        document.withSynchronizedEditor { result in
            if case .success = result { completed = true }
        }
        #expect(completed)
        #expect(!document.needsEditorSynchronization)
    }

    @Test func actionWaitsForRemoteEditAndOnlyTemporarilyPermitsSave() throws {
        let document = document()
        var release: ((Result<Void, Error>) -> Void)?
        document.synchronizeEditor = { release = $0 }
        defer { document.synchronizeEditor = nil; release = nil }
        var observedText: String?
        var permitted = false
        document.withSynchronizedEditor { result in
            guard case .success = result else { return }
            observedText = document.text
            permitted = !document.needsEditorSynchronization
        }
        #expect(observedText == nil)
        #expect(document.needsEditorSynchronization)
        #expect(throws: EditorDocument.DocumentError.self) { try document.save() }
        // Explicitly deliver the last browser edit before acknowledging the flush.
        document.applyLiveEditorEdit(replacedRange: NSRange(location: 6, length: 5), replacement: "中文😀")
        let acknowledge = try #require(release)
        acknowledge(.success(()))
        #expect(observedText == "class 中文😀 {}")
        #expect(permitted)
        #expect(document.needsEditorSynchronization)
    }

    @Test func failedDrainNeverGrantsSynchronousSavePermission() {
        let document = document()
        document.synchronizeEditor = { $0(.failure(EditorDocument.DocumentError.editorNotSynchronized)) }
        defer { document.synchronizeEditor = nil }
        var failed = false
        document.withSynchronizedEditor { result in
            if case .failure = result { failed = true }
            #expect(document.needsEditorSynchronization)
        }
        #expect(failed)
        #expect(document.needsEditorSynchronization)
        #expect(!document.isDirty)
    }

    @Test func nestedActionKeepsOuterSynchronizationScope() {
        let document = document()
        var drainCount = 0
        document.synchronizeEditor = { completion in drainCount += 1; completion(.success(())) }
        defer { document.synchronizeEditor = nil }
        document.withSynchronizedEditor { _ in
            document.withSynchronizedEditor { _ in #expect(!document.needsEditorSynchronization) }
            #expect(!document.needsEditorSynchronization)
        }
        #expect(drainCount == 1)
        #expect(document.needsEditorSynchronization)
    }
    @Test func concurrentSaveAndCloseShareOneDrainAndIgnoreDuplicateAcknowledgments() throws {
        let document = document()
        var acknowledge: ((Result<Void, Error>) -> Void)?
        var drains = 0
        document.synchronizeEditor = { drains += 1; acknowledge = $0 }
        defer { document.synchronizeEditor = nil; acknowledge = nil }
        var actions: [String] = []
        document.withSynchronizedEditor { _ in
            #expect(!document.needsEditorSynchronization)
            actions.append("save")
        }
        document.withSynchronizedEditor { _ in
            #expect(!document.needsEditorSynchronization)
            actions.append("close")
        }
        #expect(drains == 1)
        #expect(actions.isEmpty)
        let complete = try #require(acknowledge)
        complete(.success(()))
        complete(.success(()))
        #expect(actions == ["save", "close"])
        #expect(document.needsEditorSynchronization)
    }

    @Test func previousDrainAcknowledgmentCannotReleaseNextSave() throws {
        let document = document()
        var acknowledgments: [(Result<Void, Error>) -> Void] = []
        document.synchronizeEditor = { acknowledgments.append($0) }
        defer { document.synchronizeEditor = nil; acknowledgments.removeAll() }
        var savedSnapshots: [String] = []
        document.withSynchronizedEditor { result in
            if case .success = result { savedSnapshots.append(document.text) }
        }
        let first = try #require(acknowledgments.first)
        first(.success(()))
        document.withSynchronizedEditor { result in
            if case .success = result { savedSnapshots.append(document.text) }
        }
        #expect(acknowledgments.count == 2)
        first(.success(()))
        first(.failure(EditorDocument.DocumentError.editorNotSynchronized))
        #expect(savedSnapshots == ["class Probe {}"])
        // Only the second drain may release the action after its final edit arrives.
        document.applyLiveEditorText("class Latest {}")
        let second = try #require(acknowledgments.last)
        second(.success(()))
        #expect(savedSnapshots == ["class Probe {}", "class Latest {}"])
        #expect(document.needsEditorSynchronization)
    }
    @Test func mixedNewlinesKeepLanguageServerEditPositionsInModelCoordinates() throws {
        let document = EditorDocument(url: URL(fileURLWithPath: "/in-memory/Mixed.java"),
            text: "first\rsecond\r\n😀value\n", modificationDate: nil)
        let source = document.text as NSString
        let range = source.range(of: "value")
        document.applyLiveEditorEdit(replacedRange: range, replacement: "changed")
        let change = try #require(document.takePendingLanguageServerChanges().first)
        #expect(change.start.line == 2)
        #expect(change.start.utf16Column == 2)
        #expect(change.end.line == 2)
        #expect(change.end.utf16Column == 7)
        #expect(document.text == "first\rsecond\r\n😀changed\n")
    }

}
