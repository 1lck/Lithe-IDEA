import Foundation
import AppKit
import UniformTypeIdentifiers

/// macOS adapter for bundled background assets and security-scoped local images.
@MainActor
final class MacWorkbenchBackgroundPlatform: WorkbenchBackgroundPlatformProviding {
    private static let supportedExtensions = ["jpg", "jpeg", "png", "heic", "webp"]

    func chooseImage(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.image]
        return panel.runModal() == .OK ? panel.url : nil
    }

    func hasBundledImage(for slot: String) -> Bool {
        bundledImageURL(for: slot) != nil
    }

    func bundledImageData(for slot: String) -> Data? {
        guard let url = bundledImageURL(for: slot) else { return nil }
        return try? Data(contentsOf: url)
    }

    func makeImageAccess(for url: URL) -> WorkbenchBackgroundImageAccess? {
        let selectedURL = url.standardizedFileURL
        guard let bookmark = try? selectedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return nil
        }
        return WorkbenchBackgroundImageAccess(
            opaqueData: bookmark,
            displayName: selectedURL.lastPathComponent
        )
    }

    func loadImageData(for access: WorkbenchBackgroundImageAccess) -> WorkbenchBackgroundImageData? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: access.opaqueData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let refreshedAccess: WorkbenchBackgroundImageAccess?
        if isStale, let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            refreshedAccess = WorkbenchBackgroundImageAccess(
                opaqueData: bookmark,
                displayName: url.lastPathComponent
            )
        } else {
            refreshedAccess = nil
        }
        return WorkbenchBackgroundImageData(data: data, refreshedAccess: refreshedAccess)
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
