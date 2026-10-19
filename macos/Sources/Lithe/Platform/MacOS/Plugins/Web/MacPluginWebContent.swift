import Foundation
import LitheCoreContracts
import WebKit

// Note: 插件网页内容与宿主窗口的分工见 .agents/notes/implemented/architecture/2026-10-18-plugin-web-content-in-host-windows.md

/// Serves a plugin page from its installed package. The package is part of
/// the verified install and is only read here: nothing is unpacked, cached,
/// or written next to it, so the app bundle and the package stay unchanged.
enum MacPluginWebContent {
    static let scheme = "lithe-plugin"
    static let fileLimit = 16 * 1024 * 1024

    /// `lithe-plugin://<pluginID>/<entry>`: one origin per plugin.
    static func url(pluginID: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = pluginID
        components.path = "/" + path
        return components.url
    }

    /// Refuses network connections, remote resources, frames, inline and
    /// evaluated scripts; the page may load only its own package files.
    static func contentSecurityPolicy(pluginID: String) -> String {
        let origin = "'self' \(scheme)://\(pluginID)"
        return [
            "default-src 'none'",
            "script-src \(origin)",
            "style-src \(origin) 'unsafe-inline'",
            "img-src \(origin) data: blob:",
            "font-src \(origin) data:",
            "media-src \(origin) blob:",
            "connect-src \(origin)",
            "frame-src 'none'", "child-src 'none'", "worker-src 'none'", "object-src 'none'",
            "manifest-src 'none'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"
        ].joined(separator: "; ")
    }

    /// Resolves a request URL path to a regular file inside the package.
    /// Empty, `.` and `..` components, encoded separators, symbolic links,
    /// and anything resolving outside the package are refused.
    static func file(percentEncodedPath path: String, in packageURL: URL) throws -> URL {
        var encoded = path.split(separator: "/", omittingEmptySubsequences: false)
        guard encoded.first == "" else { throw Refusal.outsidePackage }
        encoded.removeFirst()
        let components = try encoded.map { part -> String in
            guard let component = String(part).removingPercentEncoding, !component.isEmpty, component != ".",
                  component != "..", !component.contains("/"), !component.contains("\\"), !component.contains(":"),
                  !component.contains("\0") else { throw Refusal.outsidePackage }
            return component
        }
        guard !components.isEmpty else { throw Refusal.outsidePackage }
        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        var url = root
        for component in components {
            url.appendPathComponent(component)
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            } catch {
                throw Refusal.missing
            }
            guard values.isSymbolicLink != true else { throw Refusal.outsidePackage }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw Refusal.missing }
        guard (values.fileSize ?? .max) <= fileLimit else { throw Refusal.tooLarge }
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw Refusal.outsidePackage }
        return url
    }

    static func mimeType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "txt": "text/plain; charset=utf-8"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        default: "application/octet-stream"
        }
    }

    /// The web windows of the plugins registered at launch.
    static func windows(_ plugins: [InstalledPluginPackage]) -> [PluginWebWindow] {
        plugins.flatMap { plugin in
            (plugin.descriptor.ui?.toolWindows ?? []).compactMap { window in
                window.web.map { web in
                    PluginWebWindow(
                        pluginID: plugin.descriptor.id.rawValue,
                        pluginName: plugin.manifest.displayName,
                        windowID: window.id,
                        entry: web.entry,
                        packageURL: plugin.packageURL,
                        buildSystemIDs: Set(plugin.descriptor.buildSystems.map(\.id)),
                        isInspectable: plugin.installation.origin == .localDevelopment
                    )
                }
            }
        }
    }

    /// Install-time check: every web entry is an `.html` file of the package.
    static func validateEntries(_ descriptor: DeclarativePluginDescriptor, at packageURL: URL) throws {
        for window in descriptor.ui?.toolWindows ?? [] {
            guard let entry = window.web?.entry else { continue }
            let encoded = entry.split(separator: "/", omittingEmptySubsequences: false).map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? ""
            }
            guard (entry as NSString).pathExtension.lowercased() == "html",
                  (try? file(percentEncodedPath: "/" + encoded.joined(separator: "/"), in: packageURL)) != nil else {
                throw InvalidEntry(path: entry)
            }
        }
    }

    enum Refusal: Error {
        case outsidePackage, missing, tooLarge
    }

    struct InvalidEntry: LocalizedError {
        let path: String
        var errorDescription: String? { "Invalid plugin web entry: \(path)" }
    }
}

/// Answers one page's `lithe-plugin:` requests from its own package only.
final class MacPluginWebSchemeHandler: NSObject, WKURLSchemeHandler {
    private let pluginID: String
    private let packageURL: URL
    private let policy: String

    init(pluginID: String, packageURL: URL) {
        self.pluginID = pluginID
        self.packageURL = packageURL
        policy = MacPluginWebContent.contentSecurityPolicy(pluginID: pluginID)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(CocoaError(.fileReadNoPermission))
            return
        }
        let response = Self.response(
            for: url, method: task.request.httpMethod ?? "GET", pluginID: pluginID, packageURL: packageURL, policy: policy
        )
        task.didReceive(response.head)
        if !response.body.isEmpty { task.didReceive(response.body) }
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// The response to one request; refusals are HTTP statuses so a page's
    /// `fetch` sees them like any missing file.
    static func response(
        for url: URL, method: String, pluginID: String, packageURL: URL, policy: String
    ) -> (head: HTTPURLResponse, body: Data) {
        var headers = [
            "Content-Security-Policy": policy,
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
            "Referrer-Policy": "no-referrer",
            "Cross-Origin-Resource-Policy": "same-origin"
        ]
        func reply(_ status: Int, _ body: Data = Data()) -> (head: HTTPURLResponse, body: Data) {
            headers["Content-Length"] = String(body.count)
            if headers["Content-Type"] == nil { headers["Content-Type"] = "text/plain; charset=utf-8" }
            return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
        }
        guard url.scheme == MacPluginWebContent.scheme, url.host == pluginID, url.port == nil,
              url.user == nil, url.password == nil else { return reply(403) }
        guard method == "GET" || method == "HEAD" else { return reply(405) }
        let file: URL
        do {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            file = try MacPluginWebContent.file(percentEncodedPath: path, in: packageURL)
        } catch MacPluginWebContent.Refusal.missing {
            return reply(404)
        } catch {
            return reply(403)
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return reply(404) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: MacPluginWebContent.fileLimit + 1) ?? Data(),
              data.count <= MacPluginWebContent.fileLimit else { return reply(403) }
        headers["Content-Type"] = MacPluginWebContent.mimeType(forExtension: file.pathExtension)
        if method == "HEAD" {
            let response = reply(200, data)
            return (response.head, Data())
        }
        return reply(200, data)
    }
}
