import Foundation
import LitheCoreContracts

struct MacRunFileAccess: RunFileAccess {
    let storage: any FileStorage

    func isDirectory(at url: URL) -> Bool {
        storage.metadata(for: url)?.isDirectory == true
    }

    func readData(from url: URL) throws -> Data {
        try storage.readData(from: url, options: [])
    }
}

@MainActor
final class MacRunPreferenceStore: RunPreferenceStore {
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func data(forKey key: String) -> Data? { store.data(forKey: key) }
    func string(forKey key: String) -> String? { store.string(forKey: key) }
    func setData(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func setString(_ value: String, forKey key: String) { store.set(value, forKey: key) }
}
