import Foundation

public struct TerminalLinkLocation: Equatable, Sendable {
    public let url: URL
    public let line: Int?
    public let column: Int?
    public init(url: URL, line: Int?, column: Int?) { self.url = url; self.line = line; self.column = column }
}

public enum TerminalLinkTarget: Equatable, Sendable { case file(TerminalLinkLocation); case external(URL) }

public enum TerminalLinkResolver {
    public static func resolve(
        _ rawLink: String,
        relativeTo directory: URL,
        fileExists: (URL) -> Bool
    ) -> TerminalLinkTarget? {
        let rawLink = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLink.isEmpty else { return nil }
        if let url = URL(string: rawLink), let scheme = url.scheme, !scheme.isEmpty, !url.isFileURL {
            return .external(url)
        }
        let (link, line, column) = splitLocationSuffix(rawLink)
        guard !link.isEmpty else { return nil }
        let path = URL(string: link)?.isFileURL == true
            ? URL(string: link)!.path
            : (link as NSString).expandingTildeInPath
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardizedFileURL
            : directory.appendingPathComponent(path).standardizedFileURL
        guard fileExists(url) else { return nil }
        return .file(TerminalLinkLocation(url: url, line: line, column: column))
    }

    private static func splitLocationSuffix(_ value: String) -> (String, Int?, Int?) {
        var components = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var line: Int?; var column: Int?
        if components.count >= 3, let c = Int(components.last!), let l = Int(components[components.count - 2]) {
            column = c; line = l; components.removeLast(2)
        } else if components.count >= 2, let l = Int(components.last!) {
            line = l; components.removeLast()
        }
        return (components.joined(separator: ":"), line, column)
    }
}
