import Foundation

/// Small platform-facing UI capabilities used by application orchestration.
/// Implementations may use AppKit, Qt, or another native UI toolkit.
@MainActor
protocol PlatformUI: AnyObject {
    func chooseDirectory(title: String, prompt: String) -> URL?
    func revealInFileBrowser(_ url: URL)
    func copyToClipboard(_ value: String)
}

protocol ShortcutDetector: AnyObject {
    func start()
    func stop()
}

@MainActor
protocol ShortcutDetectorFactory {
    func make(onDoubleTap: @escaping @MainActor () -> Void) -> any ShortcutDetector
}
