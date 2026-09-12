import Foundation

package enum GitFetchSubmodules: String, Codable, CaseIterable, Sendable {
    case inherit, no, onDemand, yes
}

package enum GitFetchTags: String, Codable, CaseIterable, Sendable {
    case inherit, all, none, prune
}

/// Choices for one Fetch invocation; saving Git configuration is a separate action.
package struct GitFetchOptions: Codable, Hashable, Sendable {
    package var remote: String?
    package var prune: Bool
    package var submodules: GitFetchSubmodules
    package var tags: GitFetchTags

    package init(remote: String? = nil, prune: Bool = true, submodules: GitFetchSubmodules = .inherit, tags: GitFetchTags = .inherit) {
        self.remote = remote
        self.prune = prune
        self.submodules = submodules
        self.tags = tags
    }
}

/// Rust owns both the preview and execution argument builder.
package struct GitFetchPlan: Decodable, Equatable, Sendable {
    package let options: GitFetchOptions
    package let arguments: [String]
    package var commands: [[String]]?

    package init(options: GitFetchOptions, arguments: [String]) {
        self.options = options
        self.arguments = arguments
    }

    package var commandLine: String { (commands ?? [arguments]).map { GitConsoleCommandFormatter.commandLine(arguments: $0) }.joined(separator: "\n") }
}

package struct GitFetchFailure: Error, Equatable, Sendable {
    package let message: String
    package init(_ message: String) { self.message = GitConsoleRedactor.redact(message) }
}
