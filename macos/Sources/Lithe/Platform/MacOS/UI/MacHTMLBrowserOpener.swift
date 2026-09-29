import AppKit
import Foundation

/// Chooses the HTTP handler, not the application's association with .html files.
@MainActor
struct MacHTMLBrowserOpener {
    var applicationForURL: @MainActor (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    var openURLs: @MainActor ([URL], URL) async throws -> Void = { urls, application in
        _ = try await NSWorkspace.shared.open(
            urls, withApplicationAt: application, configuration: .init()
        )
    }

    var isRegularFile: @MainActor (URL) throws -> Bool = {
        try $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }

    func open(_ url: URL) async throws {
        guard url.isFileURL, ["html", "htm"].contains(url.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard try isRegularFile(url) else { throw CocoaError(.fileReadNoSuchFile) }
        // This URL is only used to query Launch Services; no request is made.
        guard let probe = URL(string: "https://example.invalid"),
              let browser = applicationForURL(probe) else {
            throw CocoaError(.serviceApplicationNotFound, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString(
                    "Choose a default web browser in System Settings, then retry.", comment: ""
                )
            ])
        }
        try await openURLs([url], browser)
    }
}
