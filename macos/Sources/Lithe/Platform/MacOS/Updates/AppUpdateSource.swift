import Foundation
import LitheModuleAPI

/// Where the stable channel fetches its appcast and update archives.
///
/// The default is the folder of the stable feed stamped into Info.plist, which is
/// the repository's latest-release downloads. A custom source is a mirror that
/// serves those files flat under one base URL: `<base>/appcast-<arch>.xml` and
/// each archive by its file name. Sparkle still requires the EdDSA-signed feed
/// and archives, so a mirror can only redistribute builds the Lithe key signed.
/// AutoBuild always uses the official source.
struct AppUpdateSource: Equatable, Sendable {
    static let preferenceKey = "appUpdateSourceBaseURL"

    let defaultFeed: URL
    let customBase: URL?

    var isCustom: Bool { customBase != nil }
    var baseURL: URL { customBase ?? defaultFeed.deletingLastPathComponent() }
    var feedURL: URL {
        customBase.map { $0.appendingPathComponent(defaultFeed.lastPathComponent) } ?? defaultFeed
    }
    var feedFileName: String { defaultFeed.lastPathComponent }
    var host: String { baseURL.host ?? baseURL.absoluteString }

    /// The mirror copy of an archive the feed lists at `upstream`.
    func downloadURL(for upstream: URL) -> URL {
        guard let customBase, !upstream.lastPathComponent.isEmpty, upstream.lastPathComponent != "/" else {
            return upstream
        }
        return customBase.appendingPathComponent(upstream.lastPathComponent)
    }

    enum InputError: Error, Equatable {
        case invalid
        case insecure
    }

    /// Normalizes typed input to a folder URL ending in "/". A pasted appcast
    /// address is accepted and reduced to its folder.
    static func parseBase(_ text: String) -> Result<URL, InputError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return .failure(.invalid) }
        switch scheme {
        case "https": break
        case "http" where UpdateEndpointConfiguration.isLoopbackHost(host): break
        case "http": return .failure(.insecure)
        default: return .failure(.invalid)
        }
        components.scheme = scheme
        var path = components.path
        if path.lowercased().hasSuffix(".xml") {
            path = String(path[..<(path.lastIndex(of: "/") ?? path.startIndex)])
        }
        components.path = path.hasSuffix("/") ? path : path + "/"
        guard let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }

    /// Reads the saved mirror. A missing or unusable value means the default.
    static func saved(in defaults: UserDefaults, defaultFeed: URL) -> Self {
        let custom = (defaults.string(forKey: preferenceKey)).flatMap { try? parseBase($0).get() }
        return Self(defaultFeed: defaultFeed, customBase: custom == defaultFeed.deletingLastPathComponent() ? nil : custom)
    }

    static func inputMessage(_ error: InputError) -> String {
        switch error {
        case .invalid: L10n.string("Enter a full web address, such as https://mirror.example.com/lithe/.")
        case .insecure: L10n.string("Update sources must use https://. http:// is only allowed for this Mac (localhost).")
        }
    }
}

/// The newest entry of an appcast, as far as a connection test needs it.
struct AppcastLatestItem: Equatable, Sendable {
    let version: String
    let build: String
    let archive: URL

    /// Picks the item with the highest build number. Returns nil when the
    /// document is not an appcast with at least one enclosure.
    static func parse(_ data: Data) -> Self? {
        let collector = AppcastCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.items.max { compareBuilds($0.build, $1.build) == .orderedAscending }
    }

    private static func compareBuilds(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

private final class AppcastCollector: NSObject, XMLParserDelegate {
    private struct Draft {
        var version: String?
        var build: String?
        var archive: URL?
    }

    private(set) var items: [AppcastLatestItem] = []
    private var draft: Draft?
    private var text = ""
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "item" {
            draft = Draft()
            depth = 0
            return
        }
        guard draft != nil else { return }
        depth += 1
        // Deltas live inside <sparkle:deltas>; only the full archive counts.
        if name == "enclosure", depth == 1, let url = attributes["url"].flatMap(URL.init(string:)) {
            draft?.archive = url
            if let build = attributes["sparkle:version"] { draft?.build = build }
            if let version = attributes["sparkle:shortVersionString"] { draft?.version = version }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if name == "item" {
            if let draft, let archive = draft.archive, let build = draft.build {
                items.append(AppcastLatestItem(version: draft.version ?? build, build: build, archive: archive))
            }
            draft = nil
            return
        }
        guard draft != nil else { return }
        if depth == 1, !value.isEmpty {
            if name == "sparkle:version" { draft?.build = value }
            if name == "sparkle:shortVersionString" { draft?.version = value }
        }
        depth -= 1
    }
}

/// Result of checking a candidate source before it is saved.
enum UpdateSourceProbeResult: Equatable, Sendable {
    case reachable(version: String)
    case failed(String)
}

enum UpdateSourceProbe {
    /// Fetches the source's appcast and confirms the newest archive is present.
    static func run(_ source: AppUpdateSource, session: URLSession) async -> UpdateSourceProbeResult {
        do {
            var request = URLRequest(url: source.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            let (data, response) = try await session.data(for: request)
            if let failure = httpFailure(response, host: source.host) { return .failed(failure) }
            guard let latest = AppcastLatestItem.parse(data) else {
                return .failed(String(format: L10n.string("No update feed was found at this address. The source must provide %@ next to the update archives."),
                    source.feedFileName))
            }
            request = URLRequest(url: source.downloadURL(for: latest.archive), cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 20)
            request.httpMethod = "HEAD"
            let (_, archiveResponse) = try await session.data(for: request)
            if (archiveResponse as? HTTPURLResponse)?.statusCode == 404 {
                return .failed(String(format: L10n.string("The source lists Lithe %@ but does not provide %@."),
                    latest.version, latest.archive.lastPathComponent))
            }
            if let failure = httpFailure(archiveResponse, host: source.host) { return .failed(failure) }
            return .reachable(version: latest.version)
        } catch {
            return .failed(UpdateDownloadFailure(error)?.message(host: source.host)
                ?? error.localizedDescription)
        }
    }

    private static func httpFailure(_ response: URLResponse, host: String) -> String? {
        guard let response = response as? HTTPURLResponse else {
            return UpdateDownloadFailure.invalidResponse.message(host: host)
        }
        guard !(200..<300).contains(response.statusCode) else { return nil }
        return UpdateDownloadFailure.httpStatus(response.statusCode).message(host: host)
    }
}
