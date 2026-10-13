import AppKit
import Foundation

/// File URLs use the native pasteboard format shared with Finder.
@MainActor
enum MacFileClipboard {
    static func write(_ urls: [URL], to pasteboard: NSPasteboard) -> Bool {
        guard !urls.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    static func read(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }
}
