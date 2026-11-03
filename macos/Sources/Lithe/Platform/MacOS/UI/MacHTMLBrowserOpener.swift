import LitheModuleAPI
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
        guard let probe = URL(string: "https://example.invalid") else { throw CocoaError(.fileReadUnsupportedScheme) }
        try await openURLs([url], browser(handling: probe))
    }

    /// Opens an http or https address in the web browser. Other schemes, and
    /// addresses without a host, are refused so a caller cannot reach another
    /// application through this entry.
    func openWeb(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try await openURLs([url], browser(handling: url))
    }

    private func browser(handling url: URL) throws -> URL {
        guard let browser = applicationForURL(url) else {
            throw CocoaError(.serviceApplicationNotFound, userInfo: [
                NSLocalizedDescriptionKey: L10n.string(key: "Choose a default web browser in System Settings, then retry.")
            ])
        }
        return browser
    }
}
