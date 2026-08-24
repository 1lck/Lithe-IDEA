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
    func projectTreeRowHeightDefaultsPersistsAndRestores() {
        let store = AppSettingsTestStore()
        let settings = AppSettings(store: store)

        #expect(settings.projectTreeRowHeight == 24)

        settings.projectTreeRowHeight = 29
        #expect(AppSettings(store: store).projectTreeRowHeight == 29)

        settings.restoreDefaults()
        #expect(settings.projectTreeRowHeight == 24)
        #expect(AppSettings(store: store).projectTreeRowHeight == 24)
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

    @Test
    func workbenchBackgroundDisplayOptionsPersistAndRestoreDefaults() {
        let store = AppSettingsTestStore()
        let settings = AppSettings(store: store)

        #expect(settings.workbenchBackgroundOpacity == 0.22)

        settings.workbenchBackgroundOpacity = 0.35
        settings.setWorkbenchBackgroundPreset(.builtIn01)

        let restored = AppSettings(store: store)
        #expect(restored.workbenchBackgroundOpacity == 0.35)
        #expect(restored.workbenchBackgroundPreset == .builtIn01)

        restored.restoreDefaults()
        #expect(restored.workbenchBackgroundOpacity == 0.22)
        #expect(restored.workbenchBackgroundPreset == nil)
    }

    @Test
    func workbenchBackgroundConfigurationUsesPortableBundledSlotData() throws {
        let configuration = WorkbenchBackgroundConfiguration.bundled(slot: "03", opacity: 0.42)

        let encoded = try JSONEncoder().encode(configuration)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let source = try #require(json["source"] as? [String: Any])

        #expect(json["version"] as? Int == 1)
        #expect(json["opacity"] as? Double == 0.42)
        #expect(source["kind"] as? String == "bundled")
        #expect(source["bundledSlot"] as? String == "03")
        #expect(source["bookmark"] == nil)
        #expect(source["path"] == nil)
    }

    @Test
    func workbenchBackgroundConfigurationRejectsInvalidPortableValues() {
        let invalid = WorkbenchBackgroundConfiguration(
            version: 1,
            source: .bundled(bundledSlot: "11"),
            opacity: 2
        )

        #expect(invalid.normalized == .none(opacity: 1))
    }

    @Test
    func workbenchBackgroundOpacityIsBoundedBeforePersistingOrRendering() {
        let settings = AppSettings(store: AppSettingsTestStore())

        settings.workbenchBackgroundOpacity = 2
        #expect(settings.workbenchBackgroundOpacity == 1)
        #expect(settings.workbenchBackground.opacity == 1)

        settings.workbenchBackgroundOpacity = 0
        #expect(settings.workbenchBackgroundOpacity == 0.05)
        #expect(settings.workbenchBackground.opacity == 0.05)
    }

    @Test
    func legacyWorkbenchBackgroundPresetMigratesToPortableConfiguration() {
        let store = AppSettingsTestStore()
        store.set("builtIn03", forKey: "settings.workbenchBackgroundPreset")
        store.set(0.42, forKey: "settings.workbenchBackgroundOpacity")

        let settings = AppSettings(store: store)

        #expect(settings.workbenchBackground == .bundled(slot: "03", opacity: 0.42))
        #expect(settings.workbenchBackgroundPreset == .builtIn03)
    }

    @Test
    func unavailableBundledSlotKeepsThePortableSelectionWithoutEnablingTransparency() {
        let store = AppSettingsTestStore()
        let configuration = WorkbenchBackgroundConfiguration.bundled(slot: "04", opacity: 0.42)
        store.set(try? JSONEncoder().encode(configuration), forKey: "settings.workbenchBackground")

        let settings = AppSettings(store: store)

        #expect(settings.workbenchBackgroundPreset == .builtIn04)
        #expect(settings.hasConfiguredWorkbenchBackground)
        #expect(!settings.hasWorkbenchBackgroundImage)
    }

    @Test
    func workbenchBackgroundUsesTheInjectedPlatformForBundledAssets() {
        let imageData = Data([0x01, 0x02])
        let platform = WorkbenchBackgroundPlatformTestDouble(
            bundledImages: ["01": imageData]
        )
        let settings = AppSettings(
            store: AppSettingsTestStore(),
            logDirectoryProvider: TestLogDirectoryProvider(),
            workbenchBackgroundPlatform: platform
        )

        settings.setWorkbenchBackgroundPreset(.builtIn01)

        #expect(settings.hasWorkbenchBackgroundImage)
        #expect(settings.loadWorkbenchBackgroundImageData() == imageData)
    }

    @Test
    func customBackgroundKeepsOpaqueAccessOutOfPortableConfiguration() throws {
        let store = AppSettingsTestStore()
        let access = WorkbenchBackgroundImageAccess(
            opaqueData: Data([0xAA, 0xBB]),
            displayName: "wallpaper.png"
        )
        let platform = WorkbenchBackgroundPlatformTestDouble(imageAccess: access)
        let settings = AppSettings(
            store: store,
            logDirectoryProvider: TestLogDirectoryProvider(),
            workbenchBackgroundPlatform: platform
        )

        #expect(settings.setWorkbenchBackgroundImage(URL(fileURLWithPath: "/test/wallpaper.png")))

        let data = try #require(store.data(forKey: "settings.workbenchBackground"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let source = try #require(json["source"] as? [String: Any])
        #expect(source["kind"] as? String == "custom")
        #expect(source["opaqueData"] == nil)
        #expect(source["path"] == nil)
        #expect(source["bookmark"] == nil)

        let restored = AppSettings(
            store: store,
            logDirectoryProvider: TestLogDirectoryProvider(),
            workbenchBackgroundPlatform: platform
        )
        #expect(restored.workbenchBackgroundImageAccess == access)
    }

    @Test
    func unavailableCustomBackgroundIsClearedThroughThePlatformPort() {
        let access = WorkbenchBackgroundImageAccess(
            opaqueData: Data([0xCC]),
            displayName: "missing.png"
        )
        let platform = WorkbenchBackgroundPlatformTestDouble(imageAccess: access)
        let settings = AppSettings(
            store: AppSettingsTestStore(),
            logDirectoryProvider: TestLogDirectoryProvider(),
            workbenchBackgroundPlatform: platform
        )
        #expect(settings.setWorkbenchBackgroundImage(URL(fileURLWithPath: "/test/missing.png")))

        #expect(settings.loadWorkbenchBackgroundImageData() == nil)
        #expect(settings.workbenchBackground == .none(opacity: 0.22))
        #expect(settings.workbenchBackgroundImageError != nil)
    }
}

@MainActor
private final class WorkbenchBackgroundPlatformTestDouble: WorkbenchBackgroundPlatformProviding {
    private let bundledImages: [String: Data]
    private let imageAccess: WorkbenchBackgroundImageAccess?

    init(
        bundledImages: [String: Data] = [:],
        imageAccess: WorkbenchBackgroundImageAccess? = nil
    ) {
        self.bundledImages = bundledImages
        self.imageAccess = imageAccess
    }

    func chooseImage(title: String, prompt: String) -> URL? { nil }

    func hasBundledImage(for slot: String) -> Bool {
        bundledImages[slot] != nil
    }

    func bundledImageData(for slot: String) -> Data? {
        bundledImages[slot]
    }

    func makeImageAccess(for url: URL) -> WorkbenchBackgroundImageAccess? {
        imageAccess
    }

    func loadImageData(for access: WorkbenchBackgroundImageAccess) -> WorkbenchBackgroundImageData? {
        nil
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
