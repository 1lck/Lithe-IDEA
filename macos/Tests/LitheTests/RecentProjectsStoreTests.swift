import Foundation
import Testing
@testable import Lithe

/// The store delegates retention to `workspace.recentProjects.reduce`; these
/// cases pin the macOS projection of the shared fixture (macOS has no pins).
struct RecentProjectsStoreTests {
    private struct Fixture: Decodable { let defaultCapacity: Int }

    @Test
    func recordingKeepsTheSharedDefaultCapacityNewestFirst() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/workspace/recent-projects-v1.json"))
        let capacity = try JSONDecoder().decode(Fixture.self, from: data).defaultCapacity
        let store = RecentProjectsTestStore()
        let projects = RecentProjectsStore(store: store)
        let stored = (0...capacity).map { index in
            RecentProject(path: "/tmp/lithe-recent-\(index)", lastOpened: Date(timeIntervalSince1970: TimeInterval(index)), branch: nil)
        }
        store.set(try JSONEncoder().encode(Array(stored.reversed().dropFirst(2)) + stored.suffix(2)), forKey: "lithe.recent-projects")

        let loaded = projects.load()
        #expect(loaded.count == capacity)
        #expect(loaded.first?.path == "/tmp/lithe-recent-\(capacity)")
        #expect(!loaded.contains { $0.path == "/tmp/lithe-recent-0" })

        let reopened = projects.record(URL(fileURLWithPath: "/tmp/lithe-recent-1"), branch: "main", in: loaded)
        #expect(reopened.count == capacity)
        #expect(reopened.first?.path == "/tmp/lithe-recent-1")
        #expect(reopened.first?.branch == "main")
        #expect(projects.load().map(\.path) == reopened.map(\.path))
    }

    @Test
    func removingAProjectKeepsTheOthersInOrder() {
        let store = RecentProjectsTestStore()
        let projects = RecentProjectsStore(store: store)
        let first = projects.record(URL(fileURLWithPath: "/tmp/lithe-recent-a"), in: [])
        let both = projects.record(URL(fileURLWithPath: "/tmp/lithe-recent-b"), branch: "dev", in: first)
        let remaining = projects.remove(both[1], from: both)
        #expect(remaining.map(\.path) == ["/tmp/lithe-recent-b"])
        #expect(remaining.first?.branch == "dev")
    }
}

private final class RecentProjectsTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
