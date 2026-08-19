import Foundation

package enum RuntimeToolSource: String, Codable, Hashable, Sendable {
    case bundled
    case project
    case environment
    case path
    case homebrew
    case xcode
    case system
    case custom

    package var displayName: String {
        switch self {
        case .bundled: "Bundled"
        case .project: "Project"
        case .environment: "Environment"
        case .path: "PATH"
        case .homebrew: "Homebrew"
        case .xcode: "Xcode Command Line Tools"
        case .system: "System"
        case .custom: "Custom"
        }
    }
}

package struct RuntimeToolCandidate: Identifiable, Equatable, Sendable {
    package let command: String
    package let executableURL: URL
    package let source: RuntimeToolSource
    package let detail: String?

    package var id: String {
        command + "\u{1F}" + executableURL.standardizedFileURL.path
    }

    package init(
        command: String,
        executableURL: URL,
        source: RuntimeToolSource,
        detail: String? = nil
    ) {
        self.command = command
        self.executableURL = executableURL.standardizedFileURL
        self.source = source
        self.detail = detail
    }
}

package struct LanguageToolCommandResult: Equatable, Sendable {
    package let output: String
    package let exitCode: Int32

    package init(output: String, exitCode: Int32) {
        self.output = output
        self.exitCode = exitCode
    }

    package var succeeded: Bool { exitCode == 0 }
}

package protocol LanguageToolCommandRunning: Sendable {
    func runLanguageToolCommand(
        operationID: String,
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeoutMilliseconds: Int
    ) -> LanguageToolCommandResult
}

package protocol LanguageToolSettingsStoring: AnyObject {
    func loadLanguageToolExecutablePaths() -> [String: String]
    func saveLanguageToolExecutablePaths(_ paths: [String: String])
}
