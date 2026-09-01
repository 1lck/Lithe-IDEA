import Foundation
import LitheCoreContracts
import LitheDebugModule

enum MacDebugSteppingFilterStoreError: LocalizedError {
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidData:
            "Saved debugger stepping filters could not be read."
        }
    }
}

final class MacDebugSteppingFilterStore: DebugSteppingFilterPersisting, @unchecked Sendable {
    private static let keyPrefix = "lithe.debug.steppingFilters."
    private let store: any KeyValueStore
    private let lock = NSLock()

    init(store: any KeyValueStore) {
        self.store = store
    }

    func loadSteppingFilters(adapterID: String) throws -> DebugSteppingFilters? {
        lock.lock(); defer { lock.unlock() }
        guard let data = store.data(forKey: key(adapterID)) else { return nil }
        do {
            return try JSONDecoder().decode(DebugSteppingFilters.self, from: data)
        } catch {
            throw MacDebugSteppingFilterStoreError.invalidData
        }
    }

    func saveSteppingFilters(_ filters: DebugSteppingFilters, adapterID: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(filters)
        lock.lock(); defer { lock.unlock() }
        store.set(data, forKey: key(adapterID))
    }

    private func key(_ adapterID: String) -> String {
        Self.keyPrefix + adapterID
    }
}
