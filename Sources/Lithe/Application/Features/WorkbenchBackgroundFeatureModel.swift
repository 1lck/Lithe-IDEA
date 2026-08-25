import Combine
import Foundation

/// Owns the workbench-background interaction workflow and image-data cache.
/// AppSettings persists only the portable source and opacity configuration.
@MainActor
final class WorkbenchBackgroundFeatureModel: ObservableObject {
    @Published private(set) var imageData: Data?
    @Published private(set) var imageError: String?

    private let settings: AppSettings
    private let platform: any WorkbenchBackgroundPlatformProviding
    private var settingsObservation: AnyCancellable?
    private var loadedSource: WorkbenchBackgroundSource?
    private var previewCache: [String: Data] = [:]

    init(
        settings: AppSettings,
        platform: any WorkbenchBackgroundPlatformProviding
    ) {
        self.settings = settings
        self.platform = platform
        settingsObservation = settings.workbenchBackgroundSourceChanges.sink { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    var hasImage: Bool { imageData != nil }

    var displayName: String? {
        settings.workbenchBackgroundPreset?.title ?? platform.customImageDisplayName
    }

    var availablePresets: [WorkbenchBackgroundPreset] {
        WorkbenchBackgroundPreset.allCases.filter {
            platform.hasBundledImage(for: $0.bundledImageSlot)
        }
    }

    func previewData(for preset: WorkbenchBackgroundPreset) -> Data? {
        let slot = preset.bundledImageSlot
        if let data = previewCache[slot] { return data }
        guard case let .loaded(data) = platform.loadBundledImageData(for: slot) else {
            return nil
        }
        previewCache[slot] = data
        return data
    }

    func chooseCustomImage() {
        switch platform.chooseCustomImage(
            title: "Choose Workbench Background",
            prompt: "Choose"
        ) {
        case .selected:
            let replacesCustomImage = settings.workbenchBackground.source.isCustom
            settings.setWorkbenchBackgroundCustomImage()
            // The portable configuration identifies every local image as
            // `custom`, so choosing a replacement does not change its source.
            // Reload explicitly in that case while keeping opacity-only updates
            // on the cached rendering path.
            if replacesCustomImage { reload(force: true) }
        case .cancelled:
            break
        case let .failed(message):
            imageError = message
        }
    }

    func selectPreset(_ preset: WorkbenchBackgroundPreset) {
        guard platform.hasBundledImage(for: preset.bundledImageSlot) else { return }
        settings.setWorkbenchBackgroundPreset(preset)
    }

    func clear() {
        platform.clearCustomImage()
        settings.clearWorkbenchBackground()
        imageData = nil
        imageError = nil
        loadedSource = WorkbenchBackgroundSource.none
    }

    func retry() {
        reload(force: true)
    }

    func reload(force: Bool = false) {
        let source = settings.workbenchBackground.source
        guard force || source != loadedSource else { return }
        loadedSource = source

        let result: WorkbenchBackgroundImageLoadResult
        switch source {
        case .none:
            imageData = nil
            imageError = nil
            return
        case let .bundled(slot):
            result = platform.loadBundledImageData(for: slot)
        case .custom:
            result = platform.loadCustomImageData()
        }

        switch result {
        case let .loaded(data):
            imageData = data
            imageError = nil
        case let .temporarilyUnavailable(message):
            imageData = nil
            imageError = message
        case let .permanentlyUnavailable(message):
            imageData = nil
            if source.isCustom {
                platform.clearCustomImage()
                settings.clearWorkbenchBackground()
                // Clearing the persisted source triggers `reload()` synchronously.
                // Set the error afterwards so the settings UI can explain why the
                // user-selected image was removed instead of silently resetting.
                imageError = message
            } else {
                imageError = message
            }
        }
    }
}
