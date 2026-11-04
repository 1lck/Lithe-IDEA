import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Turns the text of the Run and test consoles into links, using the output link matchers the
/// enabled plugins declare in their manifests.
///
/// Rust Core finds the matches and decides which file or backend function each one means;
/// this service cuts console text into lines, asks Core, and keeps what a click needs.
@MainActor
final class PluginOutputLinkService {
    /// The console a text belongs to; a matcher without a scope applies to both.
    enum Scope: String {
        case run
        case test
    }

    /// What clicking a link does.
    enum Destination: Equatable {
        /// Opens a file that exists.
        case file(path: String, line: Int?, column: Int?)
        /// Asks the plugin's backend where the file is.
        case ask(Question)
    }

    /// A `resolve` link: the plugin function to call with the groups the matcher captured.
    ///
    /// It travels inside the text as a URL so a link carries all it needs and the service keeps
    /// no table that could go stale while the console scrolls.
    struct Question: Equatable {
        let pluginID: String
        let function: String
        let groups: [String: String]
    }

    /// A stretch of console text, counted in UTF-16 units as `NSRange` does, and its link.
    struct Mark: Equatable {
        let range: NSRange
        let destination: Destination
    }

    /// Read from the URL code below, which is not tied to the main actor.
    nonisolated static let linkScheme = "lithe-plugin-link"
    /// Core refuses a request with more lines, sources or roots than these.
    private static let maxLinesPerRequest = 256
    private static let maxSources = 64
    private static let maxRoots = 16
    /// Core scans this many bytes of a line; a longer line is cut before it is sent.
    private static let maxLineLength = 4096
    private static let resolveTimeout = Duration.seconds(10)

    private let matching: any PluginOutputLinkMatching
    private let sources: @MainActor () -> [PluginOutputLinkSource]

    /// `sources` lists the plugins that are enabled right now and declare matchers.
    init(matching: any PluginOutputLinkMatching, sources: @escaping @MainActor () -> [PluginOutputLinkSource]) {
        self.matching = matching
        self.sources = sources
    }

    // MARK: Finding links

    /// The links in `text`. A link to a file the plugin named is kept only when that file exists.
    func marks(in text: String, scope: Scope, workspaceRoots: [URL], fileExists: (URL) -> Bool) -> [Mark] {
        let sources = Array(sources().prefix(Self.maxSources))
        // Most users have no matcher, and their console pays nothing for this feature.
        guard !sources.isEmpty, !workspaceRoots.isEmpty, !text.isEmpty else { return [] }
        let roots = workspaceRoots.prefix(Self.maxRoots).map(\.path)
        var marks: [Mark] = []
        for batch in Self.batches(of: Self.lines(of: text)) {
            let links: [PluginOutputLink]
            do {
                links = try matching.links(scope: scope.rawValue, workspaceRoots: roots, sources: sources,
                                           lines: batch.map(\.text))
            // log-exempt: the console text stays readable and the matchers were validated when the plugin was installed
            } catch {
                continue
            }
            marks += links.compactMap { Self.mark(for: $0, in: batch, fileExists: fileExists) }
        }
        return marks
    }

    private struct Line {
        let offset: Int
        let text: String
    }

    private static func lines(of text: String) -> [Line] {
        let string = text as NSString
        var lines: [Line] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { _, range, _, _ in
            guard range.length > 0 else { return }
            let kept = clipped(range, in: string)
            lines.append(Line(offset: kept.location, text: string.substring(with: kept)))
        }
        return lines
    }

    /// Cuts a long line to `maxLineLength` without splitting a character.
    private static func clipped(_ range: NSRange, in string: NSString) -> NSRange {
        guard range.length > maxLineLength else { return range }
        let head = string.rangeOfComposedCharacterSequences(for: NSRange(location: range.location, length: maxLineLength))
        return NSIntersectionRange(head, range)
    }

    private static func batches(of lines: [Line]) -> [[Line]] {
        stride(from: 0, to: lines.count, by: maxLinesPerRequest).map {
            Array(lines[$0..<min($0 + maxLinesPerRequest, lines.count)])
        }
    }

    private static func mark(for link: PluginOutputLink, in batch: [Line], fileExists: (URL) -> Bool) -> Mark? {
        guard batch.indices.contains(link.line) else { return nil }
        let range = NSRange(location: batch[link.line].offset + link.start, length: link.length)
        switch link.target {
        case .location(let paths, let line, let column):
            guard let path = paths.first(where: { fileExists(URL(fileURLWithPath: $0)) }) else { return nil }
            return Mark(range: range, destination: .file(path: path, line: line, column: column))
        case .resolve(let function, let groups):
            return Mark(range: range, destination: .ask(Question(pluginID: link.pluginID, function: function, groups: groups)))
        }
    }

    // MARK: Answering a click

    /// Asks the plugin's backend for the location a `resolve` link means; nil when it has none.
    /// A link that outlived its plugin, or a matcher the plugin dropped, is answered with nil
    /// without calling anything.
    func location(answering question: Question, backends: any PluginBackendRequesting,
                  context: PluginWorkspaceContextReference?) async throws -> PluginOutputLinkLocation? {
        guard declares(question) else { return nil }
        let groups = ToolingJSONValue.object(question.groups.mapValues { .string($0) })
        let reply = try await backends.invokePluginFunction(
            question.function, params: .object(["groups": groups]), ofPlugin: question.pluginID,
            context: context, timeout: Self.resolveTimeout, progress: { _ in })
        return try matching.location(ofResolution: reply)
    }

    private func declares(_ question: Question) -> Bool {
        sources().contains { source in
            source.pluginID == question.pluginID && source.matchers.contains { $0.resolveFunction == question.function }
        }
    }
}

// MARK: - Link URLs

extension PluginOutputLinkService.Question {
    private static let host = "resolve"

    /// `lithe-plugin-link://resolve?plugin=…&function=…&groups=<JSON>`
    var url: URL {
        var components = URLComponents()
        components.scheme = PluginOutputLinkService.linkScheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "plugin", value: pluginID),
            URLQueryItem(name: "function", value: function),
            URLQueryItem(name: "groups", value: Self.encode(groups)),
        ]
        // The three parts are plain strings, so the components always form a URL.
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme == PluginOutputLinkService.linkScheme, url.host == Self.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let plugin = items.first(where: { $0.name == "plugin" })?.value,
              let function = items.first(where: { $0.name == "function" })?.value,
              let groups = items.first(where: { $0.name == "groups" })?.value.flatMap(Self.decode) else { return nil }
        self.init(pluginID: plugin, function: function, groups: groups)
    }

    // Sorted keys make equal questions equal URLs, so a re-render does not look like a change.
    private static func encode(_ groups: [String: String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(groups)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func decode(_ text: String) -> [String: String]? {
        // log-exempt: a URL whose groups are not our JSON is not one of our links and is ignored
        try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))
    }
}

// MARK: - Sources

extension PluginOutputLinkSource {
    /// The enabled plugins that declare matchers, in plugin ID order. A plugin of the live
    /// registry replaces the same plugin registered at launch, which an update may have changed.
    static func sources(launchRegistered: [InstalledPluginPackage], live: [InstalledPluginPackage]) -> [PluginOutputLinkSource] {
        var byPlugin: [String: PluginOutputLinkSource] = [:]
        for package in launchRegistered + live {
            let pluginID = package.descriptor.id.rawValue
            let matchers = package.descriptor.outputLinkMatchers
            byPlugin[pluginID] = matchers.isEmpty ? nil : PluginOutputLinkSource(pluginID: pluginID, matchers: matchers)
        }
        return byPlugin.values.sorted { $0.pluginID < $1.pluginID }
    }
}
