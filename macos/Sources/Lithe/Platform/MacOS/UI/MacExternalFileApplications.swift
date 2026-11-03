import AppKit
import Foundation
import LitheModuleAPI
import UniformTypeIdentifiers

// Note: 系统打开方式边界见 .agents/notes/implemented/feature/2026-11-03-macos-open-with.md
@MainActor
enum MacExternalFileApplications {
    static func applications(toOpen file: URL) -> [ExternalFileApplication] {
        guard file.isFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return [] }
        let workspace = NSWorkspace.shared
        let defaultURL = workspace.urlForApplication(toOpen: file)?.standardizedFileURL
        var seen = Set<URL>()
        let urls = (defaultURL.map { [$0] } ?? []) + workspace.urlsForApplications(toOpen: file)
        return urls.compactMap { url -> ExternalFileApplication? in
            let url = url.standardizedFileURL
            guard seen.insert(url).inserted else { return nil }
            return ExternalFileApplication(
                url: url, name: FileManager.default.displayName(atPath: url.path), isDefault: url == defaultURL,
                iconData: menuIconData(workspace.icon(forFile: url.path))
            )
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    private static func menuIconData(_ image: NSImage) -> Data? {
        // Serializing every application-icon representation decodes large 1024pt
        // artwork while opening the menu. Rasterize only the 16pt menu icon at 2x.
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32),
                   from: .zero, operation: .copy, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }

    static func chooseApplication() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.string("Choose an Application")
        panel.prompt = L10n.string("Open")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }

    static func openFile(_ file: URL, withApplicationAt application: URL?) async throws {
        guard file.isFileURL,
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard let application = application ?? NSWorkspace.shared.urlForApplication(toOpen: file) else {
            throw CocoaError(.serviceApplicationNotFound)
        }
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: .init())
    }

    static func findOnAppStore(for file: URL) throws {
        var components = URLComponents()
        components.scheme = "macappstore"
        components.host = "search.itunes.apple.com"
        components.path = "/WebObjects/MZSearch.woa/wa/search"
        components.queryItems = [
            URLQueryItem(name: "mt", value: "12"),
            URLQueryItem(name: "term", value: file.pathExtension)
        ]
        guard let url = components.url, NSWorkspace.shared.open(url) else {
            throw CocoaError(.serviceApplicationNotFound)
        }
    }
}
