import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("VCS history continuation")
@MainActor
struct VcsHistoryListTests {
    @Test
    func appendsUniqueRevisionsAndStopsCyclesNoProgressAndExhaustion() async throws {
        let model = VcsHistoryListModel()
        let first = try page(["1", "1"], next: "page1")
        await model.load { cursor in
            #expect(cursor == nil)
            return first
        }
        #expect(model.entries.map(\.id) == ["1"])
        await model.load(automatically: true) { cursor in
            #expect(cursor == "page1")
            return try page(["1", "2"], next: "page2")
        }
        #expect(model.entries.map(\.id) == ["1", "2"])
        await model.load(automatically: true) { cursor in
            #expect(cursor == "page2")
            return try page(["3"], next: "page1")
        }
        #expect(model.nextCursor == nil)
        await model.load { _ in Issue.record("An exhausted list requested another page"); return first }
        model.reset()
        await model.load { _ in first }
        await model.load { _ in try page(["1"], next: "unused") }
        #expect(model.nextCursor == nil, "Duplicate-only pages cannot loop automatically")
        model.reset()
        await model.load { _ in try page([], next: "unused") }
        #expect(model.entries.isEmpty && model.nextCursor == nil)
    }

    @Test
    func failureKeepsRowsAndRetriesTheSameCursorOnlyAfterExplicitAction() async throws {
        let model = VcsHistoryListModel()
        await model.load { _ in try page(["1"], next: "page1") }
        await model.load(automatically: true) { cursor in
            #expect(cursor == "page1")
            throw URLError(.notConnectedToInternet)
        }
        #expect(model.failure != nil && !model.isLoading)
        #expect(model.entries.map(\.id) == ["1"] && model.nextCursor == "page1")
        await model.load(automatically: true) { _ in
            Issue.record("An automatic request retried a failed page")
            return try page([], next: nil)
        }
        await model.load { cursor in
            #expect(cursor == "page1")
            return try page(["2"], next: nil)
        }
        #expect(model.entries.map(\.id) == ["1", "2"])
        #expect(model.failure == nil && !model.isLoading && model.nextCursor == nil)
    }

    @Test
    func deduplicatesInflightAndIgnoresResponsesFromAResetContext() async throws {
        let model = VcsHistoryListModel()
        let reached = TestGate(), release = TestGate()
        let first = try page(["old"], next: "old-page")
        let task = Task {
            await model.load { _ in
                reached.open()
                #expect(await release.waitUntilOpen())
                return first
            }
        }
        defer { release.open(); task.cancel() }
        #expect(await reached.waitUntilOpen())
        await model.load { _ in Issue.record("Duplicate in-flight request"); return first }
        model.reset()
        await model.load { _ in try page(["new"], next: "new-page") }
        release.open()
        await task.value
        #expect(model.entries.map(\.id) == ["new"] && model.nextCursor == "new-page")
        #expect(!model.isLoading && model.failure == nil)
    }

    @Test
    func cancelledResponseIsNotPublishedAndRemainsRetryable() async throws {
        let model = VcsHistoryListModel()
        let reached = TestGate(), release = TestGate()
        let first = try page(["1"], next: nil)
        let task = Task {
            await model.load { _ in
                reached.open()
                _ = await release.waitUntilOpen()
                return first
            }
        }
        defer { release.open(); task.cancel() }
        #expect(await reached.waitUntilOpen())
        task.cancel()
        await task.value
        #expect(model.entries.isEmpty && !model.isLoading && model.failure == nil)
        await model.load { _ in first }
        #expect(model.entries.map(\.id) == ["1"])
    }

    private func page(_ ids: [String], next: String?) throws -> VcsHistoryPage {
        let entries: [[String: Any]] = ids.map { id in
            ["revision": ["id": id, "display": "r\(id)", "kind": "number"],
             "message": "Revision \(id)", "changes": [], "changesTruncated": false]
        }
        let data = try JSONSerialization.data(withJSONObject: ["entries": entries, "nextCursor": next as Any? ?? NSNull()])
        return try JSONDecoder().decode(VcsHistoryPage.self, from: data)
    }
}
