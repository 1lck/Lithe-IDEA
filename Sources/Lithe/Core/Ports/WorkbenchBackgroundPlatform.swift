import Foundation

enum WorkbenchBackgroundImageLoadResult {
    case loaded(Data)
    case temporarilyUnavailable(message: String)
    case permanentlyUnavailable(message: String)
}

enum WorkbenchBackgroundImageSelectionResult {
    case selected(displayName: String)
    case cancelled
    case failed(message: String)
}

/// Native image resources and file authorization used by the workbench background.
/// The shared preference only stores source kind and bundled slot; implementations
/// keep resource paths and authorization data platform-private.
@MainActor
protocol WorkbenchBackgroundPlatformProviding: AnyObject {
    func chooseCustomImage(title: String, prompt: String) -> WorkbenchBackgroundImageSelectionResult
    func hasBundledImage(for slot: String) -> Bool
    func loadBundledImageData(for slot: String) -> WorkbenchBackgroundImageLoadResult
    func loadCustomImageData() -> WorkbenchBackgroundImageLoadResult
    func clearCustomImage()
    var customImageDisplayName: String? { get }
}

@MainActor
final class UnavailableWorkbenchBackgroundPlatform: WorkbenchBackgroundPlatformProviding {
    func chooseCustomImage(title: String, prompt: String) -> WorkbenchBackgroundImageSelectionResult { .cancelled }
    func hasBundledImage(for slot: String) -> Bool { false }
    func loadBundledImageData(for slot: String) -> WorkbenchBackgroundImageLoadResult {
        .temporarilyUnavailable(message: "The selected built-in background is unavailable in this build.")
    }
    func loadCustomImageData() -> WorkbenchBackgroundImageLoadResult {
        .temporarilyUnavailable(message: "Background images are unavailable on this platform.")
    }
    func clearCustomImage() {}
    var customImageDisplayName: String? { nil }
}
