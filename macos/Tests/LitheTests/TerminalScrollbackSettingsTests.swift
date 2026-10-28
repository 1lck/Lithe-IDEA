import Foundation
import Testing
@testable import Lithe

/// Covers the stored terminal scrollback setting: default, clamping,
/// persistence, and reset.
@MainActor
@Suite("Terminal scrollback setting")
struct TerminalScrollbackSettingsTests {
    @Test
    func storedValueDefaultsAndClampsToTheSupportedRange() {
        let settings = AppSettings(store: TerminalScrollbackSettingsStore())
        #expect(settings.terminalScrollbackLines == AppSettings.defaultTerminalScrollbackLines)

        settings.terminalScrollbackLines = 10
        #expect(settings.terminalScrollbackLines == AppSettings.terminalScrollbackLinesRange.lowerBound)

        settings.terminalScrollbackLines = 100_000
        #expect(settings.terminalScrollbackLines == AppSettings.terminalScrollbackLinesRange.upperBound)
    }

    @Test
    func storedValuePersistsAndRestoreDefaultsResetsIt() {
        let store = TerminalScrollbackSettingsStore()
        let settings = AppSettings(store: store)
        settings.terminalScrollbackLines = 8_000
        #expect(AppSettings(store: store).terminalScrollbackLines == 8_000,
                "A new settings instance must read the value back from the store")

        settings.restoreDefaults()
        #expect(settings.terminalScrollbackLines == AppSettings.defaultTerminalScrollbackLines)
        #expect(AppSettings(store: store).terminalScrollbackLines == AppSettings.defaultTerminalScrollbackLines)
    }

    @Test
    func storedOutOfRangeValueIsClampedOnLoad() {
        let store = TerminalScrollbackSettingsStore()
        store.set(999_999, forKey: "settings.terminalScrollbackLines")
        #expect(AppSettings(store: store).terminalScrollbackLines == AppSettings.terminalScrollbackLinesRange.upperBound)
    }
}

/// Isolated defaults store so settings tests never read or write the
/// developer's real settings domain.
private final class TerminalScrollbackSettingsStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
