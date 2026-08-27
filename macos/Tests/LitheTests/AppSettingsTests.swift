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
    func backgroundConfigurationDoesNotMigrateUndistributedLegacyKeys() {
        let store = AppSettingsTestStore()
        store.set("builtIn03", forKey: "settings.workbenchBackgroundPreset")
        store.set(0.42, forKey: "settings.workbenchBackgroundOpacity")

        let settings = AppSettings(store: store)

        #expect(settings.workbenchBackground == .none())
        #expect(store.string(forKey: "settings.workbenchBackgroundPreset") == "builtIn03")
        #expect(store.object(forKey: "settings.workbenchBackgroundOpacity") as? Double == 0.42)
    }

    @Test
    func unavailableBundledSlotKeepsThePortableSelectionWithoutEnablingTransparency() {
        let store = AppSettingsTestStore()
        let configuration = WorkbenchBackgroundConfiguration.bundled(slot: "04", opacity: 0.42)
        store.set(try? JSONEncoder().encode(configuration), forKey: "settings.workbenchBackground")

        let settings = AppSettings(store: store)

        #expect(settings.workbenchBackgroundPreset == .builtIn04)
        #expect(settings.hasConfiguredWorkbenchBackground)
        #expect(settings.hasConfiguredWorkbenchBackground)
    }

    @Test
    func workbenchBackgroundFeatureLoadsBundledAssetsWithoutChangingOnOpacityUpdates() {
        let imageData = Data([0x01, 0x02])
        let platform = WorkbenchBackgroundPlatformTestDouble(
            bundledImages: ["01": imageData]
        )
        let settings = AppSettings(store: AppSettingsTestStore())
        let feature = WorkbenchBackgroundFeatureModel(settings: settings, platform: platform)

        feature.selectPreset(.builtIn01)

        #expect(feature.imageData == imageData)
        #expect(platform.bundledLoadCount == 1)

        settings.workbenchBackgroundOpacity = 0.61

        #expect(feature.imageData == imageData)
        #expect(platform.bundledLoadCount == 1)
    }

    @Test
    func customBackgroundKeepsPlatformAuthorizationOutOfPortableConfiguration() throws {
        let store = AppSettingsTestStore()
        let platform = WorkbenchBackgroundPlatformTestDouble(
            selection: .selected(displayName: "wallpaper.png")
        )
        let settings = AppSettings(store: store)
        let feature = WorkbenchBackgroundFeatureModel(settings: settings, platform: platform)

        feature.chooseCustomImage()

        let data = try #require(store.data(forKey: "settings.workbenchBackground"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let source = try #require(json["source"] as? [String: Any])
        #expect(source["kind"] as? String == "custom")
        #expect(source["opaqueData"] == nil)
        #expect(source["path"] == nil)
        #expect(source["bookmark"] == nil)

        #expect(platform.customImageDisplayName == "wallpaper.png")
    }

    @Test
    func choosingAnotherCustomBackgroundReloadsTheImageCache() {
        let firstImage = Data([0x01])
        let replacementImage = Data([0x02])
        let platform = WorkbenchBackgroundPlatformTestDouble(
            selection: .selected(displayName: "first.png"),
            customLoadResult: .loaded(firstImage)
        )
        let settings = AppSettings(store: AppSettingsTestStore())
        let feature = WorkbenchBackgroundFeatureModel(settings: settings, platform: platform)

        feature.chooseCustomImage()
        platform.setCustomLoadResult(.loaded(replacementImage))
        feature.chooseCustomImage()

        #expect(feature.imageData == replacementImage)
        #expect(platform.customLoadCount == 2)
    }

    @Test
    func macWorkbenchBackgroundPlatformRejectsReadableButUndecodableImageData() {
        let result = MacWorkbenchBackgroundPlatform.imageLoadResult(for: Data("not an image".utf8))

        guard case let .permanentlyUnavailable(message) = result else {
            Issue.record("Undecodable image data must not enable a workbench background.")
            return
        }
        #expect(message == "The selected background image could not be decoded.")
    }

    @Test
    func macWorkbenchBackgroundPlatformPrefersPackagedResourceBundle() {
        let packagedBundle = Bundle.module
        var usedDevelopmentFallback = false

        let resolvedBundle = MacWorkbenchBackgroundPlatform.resolveResourceBundle(
            packagedURL: packagedBundle.bundleURL,
            adjacentURL: nil,
            developmentBundle: {
                usedDevelopmentFallback = true
                return Bundle.main
            }
        )

        #expect(resolvedBundle.bundleURL.standardizedFileURL == packagedBundle.bundleURL.standardizedFileURL)
        #expect(!usedDevelopmentFallback)
    }

    @Test
    func temporaryCustomImageFailurePreservesTheConfiguredSelection() {
        let platform = WorkbenchBackgroundPlatformTestDouble(
            customLoadResult: .temporarilyUnavailable(message: "Drive is offline")
        )
        let settings = AppSettings(store: AppSettingsTestStore())
        settings.setWorkbenchBackgroundCustomImage()
        let feature = WorkbenchBackgroundFeatureModel(settings: settings, platform: platform)

        #expect(feature.imageData == nil)
        #expect(feature.imageError == "Drive is offline")
        #expect(settings.workbenchBackground.source.isCustom)
        #expect(platform.clearCustomImageCount == 0)
    }

    @Test
    func permanentlyUnavailableCustomImageClearsTheConfiguredSelection() {
        let platform = WorkbenchBackgroundPlatformTestDouble(
            customLoadResult: .permanentlyUnavailable(message: "Authorization is invalid")
        )
        let settings = AppSettings(store: AppSettingsTestStore())
        settings.setWorkbenchBackgroundCustomImage()
        let feature = WorkbenchBackgroundFeatureModel(settings: settings, platform: platform)

        #expect(feature.imageData == nil)
        #expect(feature.imageError == "Authorization is invalid")
        #expect(settings.workbenchBackground.source == .none)
        #expect(platform.clearCustomImageCount == 1)
    }
}

@MainActor
private final class WorkbenchBackgroundPlatformTestDouble: WorkbenchBackgroundPlatformProviding {
    private let bundledImages: [String: Data]
    private let selection: WorkbenchBackgroundImageSelectionResult
    private var customLoadResult: WorkbenchBackgroundImageLoadResult
    private(set) var bundledLoadCount = 0
    private(set) var customLoadCount = 0
    private(set) var clearCustomImageCount = 0
    var customImageDisplayName: String?

    init(
        bundledImages: [String: Data] = [:],
        selection: WorkbenchBackgroundImageSelectionResult = .cancelled,
        customLoadResult: WorkbenchBackgroundImageLoadResult = .temporarilyUnavailable(message: "Unavailable")
    ) {
        self.bundledImages = bundledImages
        self.selection = selection
        self.customLoadResult = customLoadResult
        if case let .selected(displayName) = selection {
            customImageDisplayName = displayName
        }
    }

    func chooseCustomImage(title: String, prompt: String) -> WorkbenchBackgroundImageSelectionResult { selection }

    func hasBundledImage(for slot: String) -> Bool {
        bundledImages[slot] != nil
    }

    func loadBundledImageData(for slot: String) -> WorkbenchBackgroundImageLoadResult {
        bundledLoadCount += 1
        guard let data = bundledImages[slot] else {
            return .temporarilyUnavailable(message: "Unavailable")
        }
        return .loaded(data)
    }

    func loadCustomImageData() -> WorkbenchBackgroundImageLoadResult {
        customLoadCount += 1
        return customLoadResult
    }

    func setCustomLoadResult(_ result: WorkbenchBackgroundImageLoadResult) {
        customLoadResult = result
    }

    func clearCustomImage() { clearCustomImageCount += 1 }
}

private final class AppSettingsTestStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
