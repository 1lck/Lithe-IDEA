import Foundation

enum LanguageNavigationPreview {
    private static let maximumLocationCount = 500

    static func build(
        locations: [LanguageNavigationLocation],
        openSources: [URL: String],
        readSource: (URL) -> String?
    ) -> [String: String] {
        let visibleLocations = Array(locations.prefix(maximumLocationCount))
        let grouped = Dictionary(grouping: visibleLocations) { $0.url.standardizedFileURL }
        var result: [String: String] = [:]

        for url in grouped.keys.sorted(by: { $0.path < $1.path }) {
            guard url.isFileURL,
                  WorkspaceTextFilePolicy.isReadableTextFile(url),
                  let source = openSources[url] ?? readSource(url),
                  WorkspaceTextFilePolicy.isPlainText(source) else { continue }
            for location in grouped[url, default: []] {
                if let preview = line(in: source, at: location.line) {
                    result[location.id] = preview
                }
            }
        }
        return result
    }

    static func line(in source: String, at targetLine: Int) -> String? {
        guard targetLine >= 0 else { return nil }
        let text = source as NSString
        var currentLine = 0
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            if currentLine == targetLine {
                return text.substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            currentLine += 1
            location = NSMaxRange(range)
        }
        if targetLine == 0, text.length == 0 { return "" }
        return nil
    }
}
