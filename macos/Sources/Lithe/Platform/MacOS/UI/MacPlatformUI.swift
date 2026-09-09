import AppKit
import Foundation
import UniformTypeIdentifiers

final class MacPlatformUI: PlatformUI {
    func activateApplication() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func chooseDirectory(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseFile(title: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    func revealInFileBrowser(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyToClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func markdownImageFromClipboard() -> MarkdownImageSource? {
        MarkdownClipboardImageReader.read(from: .general)
    }

    func startAccessingProject(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessingProject(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

enum MarkdownClipboardImageReader {
    private static let encodedTypes: [(NSPasteboard.PasteboardType, MarkdownImageFormat)] = [
        (.png, .png),
        (NSPasteboard.PasteboardType("Apple PNG pasteboard type"), .png),
        (NSPasteboard.PasteboardType("com.trolltech.anymime.image--png"), .png),
        (NSPasteboard.PasteboardType("public.jpeg"), .jpeg),
        (NSPasteboard.PasteboardType("public.webp"), .webp),
        (NSPasteboard.PasteboardType("public.heic"), .heic),
        (NSPasteboard.PasteboardType("public.heif"), .heif),
        (NSPasteboard.PasteboardType("public.avif"), .avif)
    ]

    static func read(from pasteboard: NSPasteboard) -> MarkdownImageSource? {
        if let fileSource = imageFileSource(from: pasteboard) {
            return fileSource
        }
        for (type, format) in encodedTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return .encoded(data: data, format: format, suggestedName: nil)
            }
        }
        if let tiffData = pasteboard.data(forType: .tiff),
           let pngData = pngData(from: tiffData) {
            return .encoded(data: pngData, format: .png, suggestedName: nil)
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiffData = image.tiffRepresentation,
              let pngData = pngData(from: tiffData) else {
            return nil
        }
        return .encoded(data: pngData, format: .png, suggestedName: nil)
    }

    private static func imageFileSource(from pasteboard: NSPasteboard) -> MarkdownImageSource? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        for object in objects {
            guard let nsURL = object as? NSURL,
                  let url = nsURL as URL?,
                  let format = MarkdownImageFormat(fileExtension: url.pathExtension),
                  let contentType = UTType(filenameExtension: url.pathExtension),
                  contentType.conforms(to: .image) else {
                continue
            }
            return .file(url: url, format: format)
        }
        return nil
    }

    private static func pngData(from imageData: Data) -> Data? {
        guard let representation = NSBitmapImageRep(data: imageData) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }
}
