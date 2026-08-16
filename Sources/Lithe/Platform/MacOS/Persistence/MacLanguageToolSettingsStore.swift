import Foundation
import LitheCoreContracts

final class MacLanguageToolSettingsStore: LanguageToolSettingsStoring {
    private static let key = "lithe.language-server-tools.executable-paths"
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func loadLanguageToolExecutablePaths() -> [String: String] {
        guard let data = store.data(forKey: Self.key),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return value
    }

    func saveLanguageToolExecutablePaths(_ paths: [String: String]) {
        guard let data = try? JSONEncoder().encode(paths) else { return }
        store.set(data, forKey: Self.key)
    }
}
