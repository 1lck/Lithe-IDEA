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
        self.arguments = arguments
        self.output = output
        self.standardOutput = standardOutput
        self.standardError = standardError
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
        let redacted = redactingURLCredentials(in: rawValue)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        guard !redacted.isEmpty else { return "''" }
        if redacted.unicodeScalars.allSatisfy({ safeShellScalars.contains($0) }) {
            return redacted
        }
        return "'\(redacted.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func redactingURLCredentials(in value: String) -> String {
        guard value.contains("://"), var components = URLComponents(string: value) else {
            return value
        }
        guard components.user != nil || components.password != nil else { return value }
        components.user = "<redacted>"
        components.password = nil
        return components.string ?? value
    }

    private static let safeShellScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
    )
}
