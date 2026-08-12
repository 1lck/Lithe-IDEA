import Foundation

struct TerminalLinkLocation: Equatable {
    let url: URL
    let line: Int?
    let column: Int?
}

enum TerminalLinkTarget: Equatable {
    case file(TerminalLinkLocation)
    case external(URL)
}

enum TerminalLinkResolver {
    /// Resolves SwiftTerm's implicit links without interpreting terminal output
    /// as commands. Trailing line and column numbers are treated as editor
    /// coordinates when present, for example `Sources/App.swift:42:7`.
    static func resolve(
        _ rawLink: String,
        relativeTo directory: URL,
        fileExists: (URL) -> Bool
    ) -> TerminalLinkTarget? {
        let rawLink = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawLink.isEmpty else { return nil }

        // Do not interpret a URL port or numeric path segment as an editor line.
        if let externalURL = URL(string: rawLink),
           let scheme = externalURL.scheme,
           !scheme.isEmpty,
           !externalURL.isFileURL {
            return .external(externalURL)
        }

        let (link, line, column) = splitLocationSuffix(rawLink)
        guard !link.isEmpty else { return nil }

        let path: String
        if let fileURL = URL(string: link), fileURL.isFileURL {
            path = fileURL.path
        } else {
            path = (link as NSString).expandingTildeInPath
        }

        let fileURL: URL
        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            fileURL = directory.appendingPathComponent(path).standardizedFileURL
        }
        guard fileExists(fileURL) else { return nil }
        return .file(
            TerminalLinkLocation(
                url: fileURL,
                line: line,
                column: column
            )
        )
    }

    private static func splitLocationSuffix(_ value: String) -> (String, Int?, Int?) {
        var components = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var line: Int?
        var column: Int?

        if components.count >= 3,
           let maybeColumn = Int(components[components.count - 1]),
           let maybeLine = Int(components[components.count - 2]) {
            column = maybeColumn
            line = maybeLine
            components.removeLast(2)
        } else if components.count >= 2,
                  let maybeLine = Int(components[components.count - 1]) {
            line = maybeLine
            components.removeLast()
        }

        return (components.joined(separator: ":"), line, column)
    }
}
