import Foundation

package enum GitConsoleOutputStream: Equatable, Sendable {
    case standardOutput
    case standardError
}

package struct GitConsoleOutputLine: Equatable, Sendable {
    package let stream: GitConsoleOutputStream
    package let text: String
}

/// One user-initiated Git process invocation shown in the Git console.
package struct GitConsoleEntry: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let timestamp: Date
    package let workingDirectory: URL
    package let arguments: [String]
    package let output: String
    package let standardOutput: String?
    package let standardError: String?
    package let exitCode: Int32

    package init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        workingDirectory: URL,
        arguments: [String],
        output: String,
        standardOutput: String? = nil,
        standardError: String? = nil,
        exitCode: Int32
    ) {
        self.id = id
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.arguments = arguments.map(GitConsoleRedactor.redact)
        self.output = GitConsoleRedactor.redact(output)
        self.standardOutput = standardOutput.map(GitConsoleRedactor.redact)
        self.standardError = standardError.map(GitConsoleRedactor.redact)
        self.exitCode = exitCode
    }

    package var succeeded: Bool { exitCode == 0 }

    package var commandLine: String {
        GitConsoleCommandFormatter.commandLine(arguments: arguments)
    }

    package var formattedArguments: String {
        GitConsoleCommandFormatter.argumentLine(arguments: arguments)
    }

    package var outputLines: [GitConsoleOutputLine] {
        if standardOutput != nil || standardError != nil {
            return GitConsoleOutputLine.lines(from: standardOutput, stream: .standardOutput)
                + GitConsoleOutputLine.lines(from: standardError, stream: .standardError)
        }
        return GitConsoleOutputLine.lines(
            from: output,
            stream: succeeded ? .standardOutput : .standardError
        )
    }

    package var copyText: String {
        let header = "[\(workingDirectory.path)] \(commandLine)"
        guard !output.isEmpty else { return header }
        return "\(header)\n\(output)"
    }
}

private extension GitConsoleOutputLine {
    static func lines(from output: String?, stream: GitConsoleOutputStream) -> [Self] {
        guard let output else { return [] }
        let trimmedOutput = output.trimmingCharacters(in: .newlines)
        guard !trimmedOutput.isEmpty else { return [] }
        return trimmedOutput
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { Self(stream: stream, text: String($0)) }
    }
}


/// Removes credentials from every console value before it can be displayed or copied.
package enum GitConsoleRedactor {
    package static func redact(_ value: String) -> String {
        guard let urlPattern else { return value }
        let source = value as NSString
        var redacted = value
        let range = NSRange(location: 0, length: source.length)
        for match in urlPattern.matches(in: value, range: range).reversed() {
            let rawURL = source.substring(with: match.range)
            let sanitizedURL = sanitizeURL(rawURL)
            redacted = (redacted as NSString).replacingCharacters(
                in: match.range,
                with: sanitizedURL
            )
        }
        return redacted
    }

    private static func sanitizeURL(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue) else { return rawValue }
        if components.user != nil || components.password != nil {
            components.user = "redacted"
            components.password = nil
        }
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                guard sensitiveQueryNames.contains(item.name.lowercased()) else { return item }
                return URLQueryItem(name: item.name, value: "redacted")
            }
        }
        return components.string ?? rawValue
    }

    private static let sensitiveQueryNames: Set<String> = [
        "access_token",
        "api_key",
        "apikey",
        "auth",
        "authorization",
        "client_secret",
        "password",
        "passwd",
        "secret",
        "token"
    ]

    private static let urlPattern = try? NSRegularExpression(
        pattern: #"(?i)\b(?:https?|ssh)://[^\s<>"']+"#
    )
}

/// Produces readable shell-like diagnostics without ever executing a shell.
package enum GitConsoleCommandFormatter {
    package static func commandLine(arguments: [String]) -> String {
        let argumentLine = argumentLine(arguments: arguments)
        return argumentLine.isEmpty ? "git" : "git \(argumentLine)"
    }

    package static func argumentLine(arguments: [String]) -> String {
        arguments.map(sanitizedArgument).joined(separator: " ")
    }

    private static func sanitizedArgument(_ rawValue: String) -> String {
        let redacted = GitConsoleRedactor.redact(rawValue)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard !redacted.isEmpty else { return "''" }
        if redacted.unicodeScalars.allSatisfy({ safeShellScalars.contains($0) }) {
            return redacted
        }
        return "'\(redacted.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let safeShellScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
    )
}
