import Foundation
import LitheDebugModule

enum MacDebugBreakpointStoreError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidData:
            "Saved breakpoints could not be read."
        }
    }
}

final class MacDebugBreakpointStore: DebugBreakpointPersisting, @unchecked Sendable {
    private static let keyPrefix = "lithe.debug.breakpoints."
    private let store: any KeyValueStore
    private let lock = NSLock()

    init(store: any KeyValueStore) {
        self.store = store
    }

    func loadBreakpoints(for workspaceURL: URL) throws -> DebugBreakpointSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let data = store.data(forKey: key(for: workspaceURL)) else { return nil }
        do {
            return try JSONDecoder().decode(DebugBreakpointSnapshot.self, from: data)
        } catch {
            throw MacDebugBreakpointStoreError.invalidData
        }
    }

    func saveBreakpoints(_ snapshot: DebugBreakpointSnapshot, for workspaceURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        lock.lock(); defer { lock.unlock() }
        store.set(data, forKey: key(for: workspaceURL))
    }

    private func key(for workspaceURL: URL) -> String {
        Self.keyPrefix + workspaceURL.standardizedFileURL.path
    }
}
