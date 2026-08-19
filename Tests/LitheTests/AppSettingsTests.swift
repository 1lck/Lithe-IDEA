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

    @Test
    func customLogDirectoryPersistsAndCanBeRestoredToDefault() {
        let store = AppSettingsTestStore()
        let settings = AppSettings(store: store)
        let customDirectory = URL(fileURLWithPath: "/tmp/lithe-test-logs", isDirectory: true)

        #expect(settings.customLogDirectory == nil)
        #expect(settings.logDirectory == settings.defaultLogDirectory)

        settings.setCustomLogDirectory(customDirectory)

        let restored = AppSettings(store: store)
        #expect(restored.customLogDirectory == customDirectory.standardizedFileURL)
        #expect(restored.logDirectory == customDirectory.standardizedFileURL)

        restored.restoreDefaults()

        #expect(restored.customLogDirectory == nil)
        #expect(AppSettings(store: store).logDirectory == restored.defaultLogDirectory)
    }

    @Test
    func logDirectoryObserversReceiveCustomAndRestoredDirectories() {
        let settings = AppSettings(store: AppSettingsTestStore())
        let customDirectory = URL(fileURLWithPath: "/tmp/lithe-observed-logs", isDirectory: true)
        var observedDirectories: [URL] = []
        settings.addLogDirectoryObserver { observedDirectories.append($0) }

        settings.setCustomLogDirectory(customDirectory)
        settings.setCustomLogDirectory(nil)

        #expect(observedDirectories == [
            customDirectory.standardizedFileURL,
            settings.defaultLogDirectory
        ])
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
