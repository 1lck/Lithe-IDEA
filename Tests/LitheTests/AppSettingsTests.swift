import Foundation
import Testing
@testable import Lithe

@Suite("App settings")
@MainActor
struct AppSettingsTests {
    @Test
    func autoSaveDefaultsToEnabledAndPersistsDisabledSelection() {
        let store = AppSettingsTestStore()
        let settings = AppSettings(store: store)

        #expect(settings.autoSave)

        settings.autoSave = false

        #expect(AppSettings(store: store).autoSave == false)
    }

    @Test
    func restoringDefaultsEnablesAutoSave() {
        let store = AppSettingsTestStore()
        let settings = AppSettings(store: store)
        settings.autoSave = false

        settings.restoreDefaults()

        #expect(settings.autoSave)
        #expect(AppSettings(store: store).autoSave)
    }
}

private final class AppSettingsTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
