import Foundation
import UniformTypeIdentifiers
import WebKit

// Note: HTML 预览作为内嵌浏览器的决策见 .agents/notes/implemented/feature/2026-10-22-html-preview-embedded-browser.md

/// The document being previewed and the directory tree its page may read.
///
/// A page is served like a static web server rooted at `rootURL`: the workspace
/// when the document is inside it (so `/assets/app.js` means the project's
/// `assets/app.js`), otherwise the document's own directory.
struct HTMLPreviewScope: Equatable {
    let documentURL: URL
    let rootURL: URL

    init(documentURL: URL, workspaceURL: URL?) {
        let document = documentURL.standardizedFileURL.resolvingSymlinksInPath()
        self.documentURL = document
        if let workspace = workspaceURL?.standardizedFileURL.resolvingSymlinksInPath(),
           LocalFileContainment.contains(workspace, document) {
            rootURL = workspace
        } else {
            rootURL = document.deletingLastPathComponent()
        }
    }

    /// Path components of `file` below the root, for deny-list checks.
    func relativeComponents(of file: URL) -> [String] {
        Array(file.pathComponents.dropFirst(rootURL.pathComponents.count))
    }
}

/// The private scheme that lets a preview page behave like it was served over
/// HTTP: a real origin for module scripts, `fetch` and `XHR`, and root-relative
/// URLs, none of which `file://` pages or `loadHTMLString` can provide.
enum HTMLPreviewURL {
    static let scheme = "lithe-html"
    static let host = "preview"

    static func isInternal(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == host
    }

    /// The URL the web view loads to show a file inside the scope root.
    static func url(forFile fileURL: URL, in scope: HTMLPreviewScope) -> URL? {
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard LocalFileContainment.contains(scope.rootURL, file) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var path = "/" + scope.relativeComponents(of: file).joined(separator: "/")
        // The slash a web server's redirect would add, so a folder typed into the
        // address bar loads at once (`folderRedirect` covers links and scripts).
        if !path.hasSuffix("/"), isDirectory(file) { path += "/" }
        components.path = path
        return components.url
    }

    /// Where a web server would redirect the address of a folder that lacks its
    /// trailing slash, or nil for any other address. A scheme handler cannot
    /// redirect, and without the slash the relative links and scripts in the
    /// folder's index page would resolve against its parent folder.
    static func folderRedirect(for url: URL, in scope: HTMLPreviewScope) -> URL? {
        guard let file = fileURL(for: url, in: scope), isDirectory(file),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !components.path.hasSuffix("/") else { return nil }
        components.path += "/"
        return components.url
    }

    private static func isDirectory(_ file: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The file a request refers to, or nil when it is malformed or would leave
    /// the root through `..` segments or a symbolic link.
    static func fileURL(for url: URL, in scope: HTMLPreviewScope) -> URL? {
        guard isInternal(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              !components.path.contains("\0") else { return nil }
        let relative = components.path.drop(while: { $0 == "/" })
        let candidate = scope.rootURL
            .appendingPathComponent(String(relative))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return LocalFileContainment.contains(scope.rootURL, candidate) ? candidate : nil
    }
}

/// Files a page may not read even though they sit below the root.
///
/// An opened repository can contain an HTML file that runs hostile script.
/// Same-origin `fetch` would let it read credentials next to the page, so the
/// preview refuses hidden entries (`.env`, `.git`, `.ssh`) and key material.
enum HTMLPreviewAccessPolicy {
    private static let deniedExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore", "jks"]

    static func isDenied(_ file: URL, in scope: HTMLPreviewScope) -> Bool {
        // The previewed document is served from its editor buffer, wherever it lives.
        if file == scope.documentURL { return false }
        return scope.relativeComponents(of: file).contains { $0.hasPrefix(".") }
            || deniedExtensions.contains(file.pathExtension.lowercased())
    }
}

enum HTMLPreviewMIMEType {
    // WebKit refuses module scripts and stylesheets served with the wrong type,
    // and the system UTType table has no entry for some web formats.
    private static let overrides: [String: String] = [
        "html": "text/html", "htm": "text/html", "xhtml": "application/xhtml+xml",
        "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
        "css": "text/css", "json": "application/json", "map": "application/json",
        "webmanifest": "application/manifest+json", "wasm": "application/wasm",
        "svg": "image/svg+xml", "txt": "text/plain", "xml": "application/xml",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "ico": "image/x-icon", "webp": "image/webp", "avif": "image/avif",
        "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg"
    ]

    static func mimeType(forExtension pathExtension: String) -> String {
        let key = pathExtension.lowercased()
        if let override = overrides[key] { return override }
        if let type = UTType(filenameExtension: key), let mime = type.preferredMIMEType { return mime }
        return "application/octet-stream"
    }
}

struct HTMLPreviewResponse: Equatable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data
}

/// Turns one request into an HTTP-style response. Pure with respect to WebKit so
/// the serving rules can be tested without a web view.
enum HTMLPreviewResponder {
    /// Larger bodies are refused instead of being mapped into memory for a preview.
    static let maximumBodyBytes = 256 * 1_024 * 1_024

    static let unavailable = text(503, "Preview unavailable")

    static func respond(to request: URLRequest, scope: HTMLPreviewScope, html: String) -> HTMLPreviewResponse {
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET" || method == "HEAD" else {
            return text(405, "Method Not Allowed", extra: ["Allow": "GET, HEAD"])
        }
        guard let url = request.url, isInitiatedByPreviewPage(request) else {
            return text(403, "Forbidden")
        }
        guard let requested = HTMLPreviewURL.fileURL(for: url, in: scope) else {
            return text(404, "Not Found")
        }

        let isHead = method == "HEAD"
        if requested == scope.documentURL {
            return document(html, isHead: isHead)
        }
        if HTMLPreviewAccessPolicy.isDenied(requested, in: scope) {
            return text(403, "Forbidden")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requested.path, isDirectory: &isDirectory) else {
            return text(404, "Not Found")
        }
        var file = requested
        if isDirectory.boolValue {
            guard let index = indexFile(in: requested, scope: scope) else {
                return text(404, "Not Found")
            }
            if index == scope.documentURL { return document(html, isHead: isHead) }
            file = index
        }
        return fileResponse(file, rangeHeader: request.value(forHTTPHeaderField: "Range"), isHead: isHead)
    }

    /// Only the preview's own pages may read local files. A remote page loaded in
    /// the same web view can embed `lithe-html://` URLs, so its subresource
    /// requests (top-level document, or `Referer`, outside the preview) are refused.
    static func isInitiatedByPreviewPage(_ request: URLRequest) -> Bool {
        if let mainDocument = request.mainDocumentURL, !HTMLPreviewURL.isInternal(mainDocument) {
            return false
        }
        if let referer = request.value(forHTTPHeaderField: "Referer") {
            guard let url = URL(string: referer), HTMLPreviewURL.isInternal(url) else { return false }
        }
        return true
    }

    private static func indexFile(in directory: URL, scope: HTMLPreviewScope) -> URL? {
        for name in ["index.html", "index.htm"] {
            let candidate = directory.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            guard LocalFileContainment.contains(scope.rootURL, candidate) else { continue }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func document(_ html: String, isHead: Bool) -> HTMLPreviewResponse {
        let body = Data(html.utf8)
        return HTMLPreviewResponse(
            statusCode: 200,
            headers: baseHeaders(contentType: "text/html; charset=utf-8", length: body.count),
            body: isHead ? Data() : body
        )
    }

    private static func fileResponse(_ file: URL, rangeHeader: String?, isHead: Bool) -> HTMLPreviewResponse {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return text(404, "Not Found")
        }
        let contentType = HTMLPreviewMIMEType.mimeType(forExtension: file.pathExtension)
        var headers = baseHeaders(contentType: contentType, length: size)
        headers["Accept-Ranges"] = "bytes"

        let range = ByteRange.parse(rangeHeader, length: size)
        if case .unsatisfiable = range {
            return text(416, "Range Not Satisfiable", extra: ["Content-Range": "bytes */\(size)"])
        }
        let selected: Range<Int>
        var status = 200
        if case let .satisfiable(bounds) = range {
            selected = bounds
            status = 206
            headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(size)"
            headers["Content-Length"] = String(bounds.count)
        } else {
            selected = 0..<size
        }
        guard selected.count <= maximumBodyBytes else {
            return text(413, "Payload Too Large")
        }
        if isHead { return HTMLPreviewResponse(statusCode: status, headers: headers, body: Data()) }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count >= selected.upperBound else {
            return text(404, "Not Found")
        }
        let body = status == 206 ? data.subdata(in: selected) : data
        return HTMLPreviewResponse(statusCode: status, headers: headers, body: body)
    }

    private static func baseHeaders(contentType: String, length: Int) -> [String: String] {
        [
            "Content-Type": contentType,
            "Content-Length": String(length),
            // Edits on disk must show up on the next reload.
            "Cache-Control": "no-store"
        ]
    }

    private static func text(_ status: Int, _ message: String, extra: [String: String] = [:]) -> HTMLPreviewResponse {
        let body = Data(message.utf8)
        var headers = baseHeaders(contentType: "text/plain; charset=utf-8", length: body.count)
        headers.merge(extra) { _, new in new }
        return HTMLPreviewResponse(statusCode: status, headers: headers, body: body)
    }

    /// A single `Range: bytes=…` request. Media elements require it to seek.
    enum ByteRange: Equatable {
        case full
        case satisfiable(Range<Int>)
        case unsatisfiable

        static func parse(_ header: String?, length: Int) -> ByteRange {
            guard let header, header.hasPrefix("bytes="), !header.contains(",") else { return .full }
            let parts = header.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return .full }
            let first = Int(parts[0])
            let last = Int(parts[1])
            switch (first, last) {
            case let (start?, end?):
                guard start <= end else { return .full }
                guard start < length else { return .unsatisfiable }
                return .satisfiable(start..<(min(end, length - 1) + 1))
            case let (start?, nil):
                guard parts[1].isEmpty else { return .full }
                guard start < length else { return .unsatisfiable }
                return .satisfiable(start..<length)
            case let (nil, suffix?):
                guard parts[0].isEmpty else { return .full }
                guard suffix > 0, length > 0 else { return .unsatisfiable }
                return .satisfiable(max(length - suffix, 0)..<length)
            default:
                return .full
            }
        }
    }
}

/// Saves a served file where the user chose, for the downloads WebKit cannot do
/// itself because the file lives behind the custom scheme.
enum HTMLPreviewFileSaver {
    /// `bufferText` is the editor's text when the file is the previewed document.
    static func save(_ source: URL, bufferText: String?, to destination: URL) throws {
        if let bufferText {
            try Data(bufferText.utf8).write(to: destination, options: .atomic)
            return
        }
        // The user may pick the file's own location in the save panel; making
        // room for the copy would then delete the only copy.
        if isSameFile(source, destination) { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Compares file identity rather than paths, which differ by case on a
    /// case-insensitive volume and through symbolic or hard links.
    private static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        guard let a = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let b = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return a.isEqual(b)
    }
}

/// Serves preview pages and their resources to the web view.
///
/// The previewed document comes from the editor buffer so unsaved edits show up;
/// everything else is read from disk, read-only, below the scope root.
final class HTMLPreviewSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private struct Snapshot {
        let scope: HTMLPreviewScope
        let html: String
    }

    private let lock = NSLock()
    // Concurrent, so one large media file does not hold up the page's scripts and styles.
    private let queue = DispatchQueue(label: "lithe.html-preview.resources", qos: .userInitiated, attributes: .concurrent)
    private var snapshot: Snapshot?
    private let tasks = LocalFileSchemeTasks()

    func update(scope: HTMLPreviewScope, html: String) {
        lock.withLock { snapshot = Snapshot(scope: scope, html: html) }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = tasks.register(urlSchemeTask)
        let request = urlSchemeTask.request
        let current = lock.withLock { snapshot }
        queue.async { [weak self] in
            let response = current.map {
                HTMLPreviewResponder.respond(to: request, scope: $0.scope, html: $0.html)
            } ?? HTMLPreviewResponder.unavailable
            // WebKit requires task callbacks on the main thread, and `stop` arrives there too.
            DispatchQueue.main.async {
                self?.deliver(response, for: request, to: urlSchemeTask, id: id)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.stop(urlSchemeTask)
    }

    private func deliver(
        _ response: HTMLPreviewResponse,
        for request: URLRequest,
        to task: any WKURLSchemeTask,
        id: ObjectIdentifier
    ) {
        // A stopped task must not be touched again.
        guard tasks.claim(id) else { return }
        guard let url = request.url,
              let http = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
              ) else {
            task.didFailWithError(CocoaError(.fileReadUnknown))
            return
        }
        task.didReceive(http)
        if !response.body.isEmpty { task.didReceive(response.body) }
        task.didFinish()
    }
}
