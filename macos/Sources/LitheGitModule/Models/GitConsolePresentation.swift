import Foundation

/// Provenance is explicit; unknown commands are never merged as automatic queries.
package enum GitExecutionSource: String, Codable, Hashable, Sendable {
    case user, background, unknown
    @TaskLocal package static var current: GitExecutionSource = .unknown
}

/// A retained snapshot sent to the pure Core presentation command.
package struct GitConsolePresentationRequest: Encodable, Hashable, Sendable {
    package let records: [Record]
    package let search: String
    package let repositoryRoots: [String]
    package init(entries: [GitConsoleEntry], search: String, repositoryRoots: [URL] = []) {
        records = entries.map(Record.init)
        self.search = search
        self.repositoryRoots = repositoryRoots.map(\.path)
    }
    package struct Line: Encodable, Hashable, Sendable {
        let stream: String
        let text: String
    }
    package struct Record: Encodable, Hashable, Sendable {
        let id: String
        let sequence: UInt64?
        let root: String
        let arguments: [String]
        let temporaryConfig: [[String]]
        let lines: [Line]
        let state: String
        let expectedExit: Bool
        let exitCode: Int32?
        let error: String?
        let executable: String?
        let progress: String?
        let source: GitExecutionSource
        let truncated: Bool
        init(_ entry: GitConsoleEntry) {
            id = entry.id.uuidString
            sequence = entry.sequence
            root = entry.workingDirectory.path
            arguments = entry.arguments
            temporaryConfig = entry.temporaryConfig.filter { $0.count == 2 }
            lines = entry.outputLines.map { Line(stream: $0.stream == .standardError ? "stderr" : "stdout", text: $0.text) }
            state = String(describing: entry.state)
            exitCode = entry.state == .completed ? entry.exitCode : nil
            error = entry.operationErrorMessage
            executable = entry.executable
            progress = entry.progressText
            source = entry.source
            expectedExit = entry.expectedExit
            truncated = entry.isOutputTruncated
        }
    }
}

/// Native rendering consumes ranges into the retained snapshot, never rewritten output.
package struct GitConsolePresentation: Decodable, Equatable, Sendable {
    package let entries: [Entry]
    package let groups: [Group]
    package let matches: [SearchHit]
    package let totalMatches: Int
    package struct Entry: Decodable, Equatable, Sendable, Identifiable {
        package let id: String
        package let repositoryLabel: String
        package let command: [CommandFragment]
        package let output: [OutputFragment]
        package let failed: Bool
    }
    package struct CommandFragment: Decodable, Equatable, Sendable, Identifiable {
        package let id: String
        package let kind: String
        package let text: String
        package let preview: String
        package let count: Int
        package let matches: Int
    }
    package struct OutputFragment: Decodable, Equatable, Sendable, Identifiable {
        package let id: String
        package let start: Int
        package let end: Int
        package let kind: String
        package let count: Int
        package let added: Int
        package let updated: Int
        package let deleted: Int
        package let matches: Int
    }
    package struct Group: Decodable, Equatable, Sendable, Identifiable {
        package let id: String
        package let recordIds: [String]
        package let matches: Int
    }
    package struct SearchHit: Decodable, Equatable, Sendable {
        package let recordId: String
        package let fragmentId: String
        package let lineIndex: Int?
        package var anchor: String { recordId + ":" + (lineIndex.map { "line-\($0)" } ?? fragmentId) }
    }
}
