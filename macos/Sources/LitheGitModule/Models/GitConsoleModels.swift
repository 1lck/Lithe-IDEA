import Foundation

package enum GitConsoleOutputStream: Equatable, Sendable {
    case standardOutput
    case standardError
}

package struct GitConsoleOutputLine: Equatable, Sendable {
    package let stream: GitConsoleOutputStream
    package let text: String
}

package enum GitConsoleEntryState: Equatable, Sendable {
    /// A preview exists but no process-start event has been received.
    case planned
    /// A process-start event confirmed the actual command.
    case running
    case completed
    /// No completed invocation was returned; process execution cannot be confirmed.
    case unconfirmed
}

/// A planned or completed Git invocation shown in the Git console.
package struct GitConsoleEntry: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let timestamp: Date
    package let workingDirectory: URL
    package let arguments: [String]
    package let output: String
    package let standardOutput: String?
    package let standardError: String?
    private let orderedOutputLines: [GitConsoleOutputLine]?
    package let exitCode: Int32
    package let state: GitConsoleEntryState
    package let durationMilliseconds: Int?
    package let operationTitle: String?
    package let operationErrorMessage: String?
    package let progressText: String?
    package let executable: String?
    package let temporaryConfig: [[String]]
    package let phase: GitPhaseProgress?
    package let remoteResult: GitRemoteOutcome?
    package let isOutputTruncated: Bool

    package init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        workingDirectory: URL,
        arguments: [String],
        output: String,
        standardOutput: String? = nil,
        standardError: String? = nil,
        orderedOutputLines: [GitConsoleOutputLine]? = nil,
        exitCode: Int32,
        state: GitConsoleEntryState = .completed,
        durationMilliseconds: Int? = nil,
        operationTitle: String? = nil,
        operationErrorMessage: String? = nil,
        progressText: String? = nil,
        isOutputTruncated: Bool = false,
        executable: String? = nil, temporaryConfig: [[String]] = [],
        phase: GitPhaseProgress? = nil, remoteResult: GitRemoteOutcome? = nil
    ) {
        self.executable = executable
        self.temporaryConfig = temporaryConfig.map { $0.map(GitConsoleRedactor.redact) }
        self.phase = phase
        self.remoteResult = remoteResult
        self.id = id
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.arguments = arguments.map(GitConsoleRedactor.redact)
        self.output = GitConsoleRedactor.redact(output)
        self.standardOutput = standardOutput.map(GitConsoleRedactor.redact)
        self.standardError = standardError.map(GitConsoleRedactor.redact)
        self.orderedOutputLines = orderedOutputLines?.map {
            GitConsoleOutputLine(stream: $0.stream, text: GitConsoleRedactor.redact($0.text))
        }
        self.exitCode = exitCode
        self.state = state
        self.durationMilliseconds = durationMilliseconds
        self.operationTitle = operationTitle
        self.progressText = progressText.map(GitConsoleRedactor.redact)
        self.isOutputTruncated = isOutputTruncated
        self.operationErrorMessage = operationErrorMessage.map(GitConsoleRedactor.redact)
    }

    package func withOperationError(_ message: String) -> Self {
        Self(id: id, timestamp: timestamp, workingDirectory: workingDirectory,
            arguments: arguments, output: output, standardOutput: standardOutput,
            standardError: standardError, orderedOutputLines: orderedOutputLines, exitCode: exitCode, state: state,
            durationMilliseconds: durationMilliseconds, operationTitle: operationTitle,
            operationErrorMessage: message, progressText: progressText, isOutputTruncated: isOutputTruncated,
            executable: executable, temporaryConfig: temporaryConfig, phase: phase, remoteResult: remoteResult)
    }

    package var succeeded: Bool { state == .completed && exitCode == 0 && operationErrorMessage == nil }

    package var commandLine: String {
        GitConsoleCommandFormatter.commandLine(arguments: arguments)
    }

    package var formattedArguments: String {
        GitConsoleCommandFormatter.argumentLine(arguments: arguments)
    }

    package var formattedTemporaryConfiguration: String {
        GitConsoleCommandFormatter.argumentLine(arguments: temporaryConfig.flatMap { pair in
            ["-c", pair.joined(separator: "=")]
        })
    }

    package var outputLines: [GitConsoleOutputLine] {
        if let orderedOutputLines { return orderedOutputLines }
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
        let configuration = temporaryConfig.map { $0.joined(separator: "=") }.joined(separator: ", ")
        let outcome = remoteResult.map { "\nRemote: \($0.remote) · \($0.succeeded ? "succeeded" : "failed")\nUpdated (\($0.updatedCount)): \($0.updatedReferences.joined(separator: ", "))\nDeleted (\($0.deletedCount)): \($0.deletedReferences.joined(separator: ", "))" } ?? ""
        let header = "[\(workingDirectory.path)] \(commandLine)"
        let status: String
        switch state {
        case .planned: status = "Planned Git command — waiting to start"
        case .running: status = "Git command is running"
        case .unconfirmed: status = "No completed Git invocation was reported"
        case .completed: status = "Exit code: \(exitCode)"
        }
        let duration = durationMilliseconds.map { " · \($0) ms" } ?? ""
        return "\(header)\n\(status)\(duration)\nGit: \(executable ?? "PATH")\nTemporary configuration: \(configuration)" + outcome + (output.isEmpty ? "" : "\n\(output)")
            + (progressText.map { "\n" + $0 } ?? "")
            + (isOutputTruncated ? "\nEarlier Git output was omitted to limit memory use." : "")
            + (operationErrorMessage.map { "\n" + $0 } ?? "")
    }
}

private extension GitConsoleOutputLine {
    static func lines(from output: String?, stream: GitConsoleOutputStream) -> [Self] {
        guard let output else { return [] }
        let trimmedOutput = output.trimmingCharacters(in: .newlines)
        guard !trimmedOutput.isEmpty else { return [] }
        return trimmedOutput
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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
