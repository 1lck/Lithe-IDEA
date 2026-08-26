import Foundation

/// One user-initiated Git process invocation shown in the Git console.
package struct GitConsoleEntry: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let timestamp: Date
    package let workingDirectory: URL
    package let arguments: [String]
    package let output: String
    package let exitCode: Int32

    package init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        workingDirectory: URL,
        arguments: [String],
        output: String,
        exitCode: Int32
    ) {
        self.id = id
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.output = output
        self.exitCode = exitCode
    }

    package var succeeded: Bool { exitCode == 0 }

    package var commandLine: String {
        GitConsoleCommandFormatter.commandLine(arguments: arguments)
    }

    package var copyText: String {
        let header = "[\(workingDirectory.path)] \(commandLine)"
        guard !output.isEmpty else { return header }
        return "\(header)\n\(output)"
    }
}

/// Produces readable shell-like diagnostics without ever executing a shell.
package enum GitConsoleCommandFormatter {
    package static func commandLine(arguments: [String]) -> String {
        (["git"] + arguments.map(sanitizedArgument)).joined(separator: " ")
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
