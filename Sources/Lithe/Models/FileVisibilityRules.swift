import Foundation

struct FileVisibilityRules: Hashable, Sendable {
    static let builtInHiddenDirectories = [
        ".git", ".worktree", ".worktrees", ".build", ".swiftpm", "node_modules", "target", "build",
        "DerivedData", ".gradle", ".next", "dist", "coverage", "design-qa-artifacts"
    ]
    static let builtInHiddenFilePatterns = [
        ".DS_Store",
        ".lithe/run/local.json",
    ]

    var hiddenDirectoryNames: [String]
    var hiddenFilePatterns: [String]

    static let `default` = FileVisibilityRules(
        hiddenDirectoryNames: builtInHiddenDirectories,
        hiddenFilePatterns: builtInHiddenFilePatterns
    )

    init(hiddenDirectoryNames: [String], hiddenFilePatterns: [String]) {
        self.hiddenDirectoryNames = Self.normalizedEntries(
            Self.builtInHiddenDirectories + hiddenDirectoryNames
        )
        self.hiddenFilePatterns = Self.normalizedEntries(
            Self.builtInHiddenFilePatterns + hiddenFilePatterns
        )
    }

    func isHidden(
        _ url: URL,
        relativeTo rootURL: URL,
        isDirectory: Bool? = nil
    ) -> Bool {
        let relativePath = relativePath(for: url, root: rootURL)
        guard !relativePath.isEmpty else { return false }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let lastComponent = components.last else { return false }

        let directoryComponents: [String]
        switch isDirectory {
        case true:
            directoryComponents = components
        case false:
            directoryComponents = Array(components.dropLast())
        case nil:
            directoryComponents = components
        }
        if directoryComponents.contains(where: isHiddenDirectoryName) {
            return true
        }
        if isDirectory == true, isHiddenDirectoryName(lastComponent) {
            return true
        }

        guard isDirectory != true else { return false }
        return hiddenFilePatterns.contains { pattern in
            Self.globMatches(pattern, value: lastComponent) ||
                Self.globMatches(pattern, value: relativePath)
        }
    }

    func isHiddenPath(_ url: URL, relativeTo rootURL: URL) -> Bool {
        isHidden(url, relativeTo: rootURL, isDirectory: nil)
    }

    func isHiddenDirectoryName(_ name: String) -> Bool {
        hiddenDirectoryNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private static func normalizedEntries(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func globMatches(_ pattern: String, value: String) -> Bool {
        let patternCharacters = Array(pattern.lowercased())
        let valueCharacters = Array(value.lowercased())
        var patternIndex = 0
        var valueIndex = 0
        var starIndex: Int?
        var starMatchIndex = 0

        while valueIndex < valueCharacters.count {
            if patternIndex < patternCharacters.count {
                let character = patternCharacters[patternIndex]
                if character == valueCharacters[valueIndex] || character == "?" {
                    patternIndex += 1
                    valueIndex += 1
                    continue
                }
            }
            if patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
                starIndex = patternIndex
                starMatchIndex = valueIndex
                patternIndex += 1
            } else if let starIndex {
                patternIndex = starIndex + 1
                starMatchIndex += 1
                valueIndex = starMatchIndex
            } else {
                return false
            }
        }

        while patternIndex < patternCharacters.count, patternCharacters[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternCharacters.count
    }
}
