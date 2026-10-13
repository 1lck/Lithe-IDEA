import Foundation

/// Small platform-facing UI capabilities used by application orchestration.
/// Implementations may use AppKit, Qt, or another native UI toolkit.
@MainActor
protocol PlatformUI: AnyObject {
    func activateApplication()
    func chooseDirectory(title: String, prompt: String) -> URL?
    func chooseFile(title: String, prompt: String) -> URL?
    func revealInFileBrowser(_ url: URL)
    func open(_ url: URL)
    func openHTMLInBrowser(_ url: URL) async throws
    func copyToClipboard(_ value: String)
    func copyFilesToClipboard(_ urls: [URL]) -> Bool
    func fileURLsFromClipboard() -> [URL]
    func markdownImageFromClipboard() -> MarkdownImageSource?
    func startAccessingProject(_ url: URL) -> Bool
    func stopAccessingProject(_ url: URL)
}

extension PlatformUI {
    func openHTMLInBrowser(_ url: URL) async throws {
        throw CocoaError(.featureUnsupported)
    }

    func copyFilesToClipboard(_ urls: [URL]) -> Bool { false }
    func fileURLsFromClipboard() -> [URL] { [] }

    func activateApplication() {}
    func startAccessingProject(_ url: URL) -> Bool { false }
    func stopAccessingProject(_ url: URL) {}
}

protocol ShortcutDetector: AnyObject {
    func start()
    func stop()
    func update(registrations: [KeyboardShortcutRegistration])
    func setSuspended(_ suspended: Bool)
}

@MainActor
protocol ShortcutDetectorFactory {
    func make(onCommand: @escaping @MainActor @Sendable (String) -> Void) -> any ShortcutDetector
}
