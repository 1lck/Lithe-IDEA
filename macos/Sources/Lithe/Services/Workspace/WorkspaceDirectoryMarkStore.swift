import Foundation
import LitheCoreContracts

/// Stores project-tree directory roles in Lithe's application preferences.
final class WorkspaceDirectoryMarkStore: WorkspaceDirectoryMarkStoring, @unchecked Sendable {
    private struct Payload: Codable {
        let version: Int
        let marks: [String: WorkspaceDirectoryMark]
    }

    private static let keyPrefix = "lithe.workspace-directory-marks."
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func loadDirectoryMarks(
        for workspaceURL: URL
    ) throws -> [String: WorkspaceDirectoryMark] {
        guard let data = store.data(forKey: key(for: workspaceURL)) else { return [:] }
        return try JSONDecoder().decode(Payload.self, from: data).marks
    }

    func saveDirectoryMarks(
        _ marks: [String: WorkspaceDirectoryMark],
        for workspaceURL: URL
    ) throws {
        let payload = Payload(version: 1, marks: marks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        store.set(try encoder.encode(payload), forKey: key(for: workspaceURL))
    }

    private func key(for workspaceURL: URL) -> String {
        Self.keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
