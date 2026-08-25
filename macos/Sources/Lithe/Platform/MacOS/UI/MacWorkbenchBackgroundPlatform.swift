import Foundation
import AppKit
import UniformTypeIdentifiers

/// macOS-private security-scoped authorization for a custom background image.
private struct WorkbenchBackgroundImageAccess: Codable {
    let opaqueData: Data
    let displayName: String
}

/// macOS adapter for bundled background assets and security-scoped local images.
@MainActor
final class MacWorkbenchBackgroundPlatform: WorkbenchBackgroundPlatformProviding {
    private static let supportedExtensions = ["jpg", "jpeg", "png", "heic", "webp"]
    private enum Key {
        static let customImageAccess = "platform.macos.workbenchBackgroundImageAccess"
    }

    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func chooseCustomImage(title: String, prompt: String) -> WorkbenchBackgroundImageSelectionResult {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        let selectedURL = url.standardizedFileURL
        do {
            let bookmark = try selectedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let access = WorkbenchBackgroundImageAccess(
                opaqueData: bookmark,
                displayName: selectedURL.lastPathComponent
            )
            store.set(try JSONEncoder().encode(access), forKey: Key.customImageAccess)
            return .selected(displayName: access.displayName)
        } catch {
            return .failed(message: "Could not save access to the selected background image.")
        }
    }

    func hasBundledImage(for slot: String) -> Bool {
        bundledImageURL(for: slot) != nil
    }

    func loadBundledImageData(for slot: String) -> WorkbenchBackgroundImageLoadResult {
        guard let url = bundledImageURL(for: slot) else {
            return .temporarilyUnavailable(message: "The selected built-in background is unavailable in this build.")
        }
        do {
            return Self.imageLoadResult(for: try Data(contentsOf: url))
        } catch {
            return .temporarilyUnavailable(message: "Could not read the selected built-in background.")
        }
    }

    func loadCustomImageData() -> WorkbenchBackgroundImageLoadResult {
        guard let accessData = store.data(forKey: Key.customImageAccess) else {
            return .permanentlyUnavailable(message: "The selected background image authorization is invalid.")
        }
        guard let access = try? JSONDecoder().decode(WorkbenchBackgroundImageAccess.self, from: accessData) else {
            return .permanentlyUnavailable(message: "The selected background image authorization is invalid.")
        }
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: access.opaqueData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // Bookmark resolution can fail while an external volume is offline
            // or the sandbox cannot currently reacquire access. Keep the user's
            // configuration and let Retry attempt resolution again.
            return .temporarilyUnavailable(message: "The selected background image is temporarily unavailable.")
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            let result = Self.imageLoadResult(for: data)
            if isStale, case .loaded = result { refreshCustomImageAccess(for: url) }
            return result
        } catch {
            // A missing external volume and a temporary permission/I/O failure
            // cannot be distinguished reliably here; preserve the selection.
            return .temporarilyUnavailable(message: "The selected background image is temporarily unavailable.")
        }
    }

    func clearCustomImage() {
        store.set(nil, forKey: Key.customImageAccess)
    }

    var customImageDisplayName: String? {
        customImageAccess?.displayName
    }

    static func imageLoadResult(for data: Data) -> WorkbenchBackgroundImageLoadResult {
        guard NSImage(data: data) != nil else {
            return .permanentlyUnavailable(message: "The selected background image could not be decoded.")
        }
        return .loaded(data)
    }

    private var customImageAccess: WorkbenchBackgroundImageAccess? {
        guard let data = store.data(forKey: Key.customImageAccess) else { return nil }
        return try? JSONDecoder().decode(WorkbenchBackgroundImageAccess.self, from: data)
    }

    private func refreshCustomImageAccess(for url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        let refreshed = WorkbenchBackgroundImageAccess(
            opaqueData: bookmark,
            displayName: url.lastPathComponent
        )
        store.set(try? JSONEncoder().encode(refreshed), forKey: Key.customImageAccess)
    }

    private func bundledImageURL(for slot: String) -> URL? {
        let directory = Bundle.module.resourceURL?
            .appendingPathComponent("WorkbenchBackgrounds", isDirectory: true)
            .appendingPathComponent(slot, isDirectory: true)
        return Self.supportedExtensions
            .map { directory?.appendingPathComponent("background.\($0)") }
            .first { url in
                guard let url else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            } ?? nil
    }
}
