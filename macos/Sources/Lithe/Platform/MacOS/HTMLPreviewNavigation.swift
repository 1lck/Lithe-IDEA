import Foundation
import WebKit

/// What the preview does with a navigation the page or the user started.
enum HTMLPreviewNavigationDecision: Equatable {
    case allow
    case cancel
    /// A new-window request. The preview is a single tab, so it loads in place.
    case loadInPlace(URL)
    case openExternally(URL)
    case download
}

struct HTMLPreviewNavigationRequest: Equatable {
    enum Target: Equatable {
        case mainFrame
        case subframe
        /// `target="_blank"` and `window.open`, which have no existing frame.
        case newWindow
    }

    var url: URL
    var type: WKNavigationType
    var target: Target
    var shouldDownload: Bool
}

/// Browser-like navigation rules. Kept free of WebKit objects (a
/// `WKNavigationAction` cannot be constructed) so the rules are unit tested.
enum HTMLPreviewNavigationPolicy {
    private static let externalSchemes: Set<String> = ["mailto", "tel", "sms"]

    static func decide(_ request: HTMLPreviewNavigationRequest) -> HTMLPreviewNavigationDecision {
        if request.shouldDownload { return .download }
        let url = request.url
        switch url.scheme?.lowercased() {
        case HTMLPreviewURL.scheme, "http", "https":
            return request.target == .newWindow ? .loadInPlace(url) : .allow
        case "about":
            // about:blank and about:srcdoc are how pages build iframes.
            return .allow
        case "javascript":
            // Runs in the page's own context, which already runs its scripts.
            return .allow
        case "blob", "data":
            // Embedded in iframes; a top-level data: or blob: navigation is a
            // phishing vector that browsers also block.
            return request.target == .subframe ? .allow : .cancel
        case let scheme? where externalSchemes.contains(scheme):
            // Handing arbitrary schemes to the system would let a remote page
            // launch any registered application, so only mail and phone links
            // clicked by the user leave the preview.
            return request.type == .linkActivated ? .openExternally(url) : .cancel
        default:
            // file: (a remote page must not read local files) and unknown schemes.
            return .cancel
        }
    }
}

enum HTMLPreviewScript {
    /// A JavaScript string literal, so the text cannot break out of the script.
    static func literal(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Maps between what the address bar shows and the URL the web view loads.
enum HTMLPreviewAddress {
    /// Local pages appear as the file they were read from, like in a browser
    /// that opened the file directly.
    static func display(for url: URL?, in scope: HTMLPreviewScope?) -> String {
        guard let url else { return "" }
        guard HTMLPreviewURL.isInternal(url) else {
            return url.absoluteString == "about:blank" ? "" : url.absoluteString
        }
        guard let scope, let file = HTMLPreviewURL.fileURL(for: url, in: scope),
              var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let source = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components.percentEncodedQuery = source?.percentEncodedQuery
        components.percentEncodedFragment = source?.percentEncodedFragment
        return components.string ?? file.absoluteString
    }

    /// Turns typed text into a URL to load, or nil when it cannot be interpreted.
    /// Local files outside the scope root cannot be served and return nil.
    static func resolve(_ input: String, in scope: HTMLPreviewScope) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\0") else { return nil }

        if text.hasPrefix("/") || text.hasPrefix("~") {
            let path = (text as NSString).expandingTildeInPath
            return HTMLPreviewURL.url(forFile: URL(fileURLWithPath: path), in: scope)
        }
        if text == "about:blank" { return URL(string: text) }
        if text.contains("://") { return resolveExplicitScheme(text, in: scope) }
        return resolveBareAddress(text)
    }

    private static func resolveExplicitScheme(_ text: String, in scope: HTMLPreviewScope) -> URL? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https":
            return components.host?.isEmpty == false ? components.url : nil
        case HTMLPreviewURL.scheme:
            return components.url.flatMap { HTMLPreviewURL.isInternal($0) ? $0 : nil }
        case "file":
            guard let internalURL = HTMLPreviewURL.url(forFile: URL(fileURLWithPath: components.path), in: scope),
                  var result = URLComponents(url: internalURL, resolvingAgainstBaseURL: false) else { return nil }
            result.percentEncodedQuery = components.percentEncodedQuery
            result.percentEncodedFragment = components.percentEncodedFragment
            return result.url
        default:
            return nil
        }
    }

    /// `example.com` and `localhost:3000` without a scheme. Plain words are not
    /// treated as hosts, so a typo does not become a network request.
    private static func resolveBareAddress(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace) else { return nil }
        let isLocal = ["localhost", "127.0.0.1", "[::1]"].contains { text.lowercased().hasPrefix($0) }
        guard isLocal || text.contains(".") else { return nil }
        guard let url = URL(string: (isLocal ? "http://" : "https://") + text),
              url.host?.isEmpty == false else { return nil }
        return url
    }
}
