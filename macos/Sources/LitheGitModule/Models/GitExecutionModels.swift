import Foundation

/// Versioned Core diagnostics. Absolute directories are native display context.
package struct GitExecutionEvent: Decodable, Sendable {
    package let operationId: String
    package let type: String
    package var invocationId: Int?
    package var workingDirectory: String?
    package var arguments: [String]?
    package var stream: String?
    package var text: String?
    package var progress: Bool?
    package var truncated: Bool?
    package var exitCode: Int32?
    package var durationMilliseconds: Int?
    package var error: Failure?

    package struct Failure: Decodable, Sendable {
        package let code: String
        package let message: String
        package var details: String?
    }
}

/// The lock protects synchronous bridge delivery and cancellation across the
/// worker/UI boundary. Only bounded snapshots cross onto the main actor.
package final class GitExecutionContext: @unchecked Sendable {
    @TaskLocal package static var current: GitExecutionContext?
    package let operationID: String
    private let lock = NSLock()
    private var cancelled = false
    private var records: [Record] = []
    private var dirty = false
    private var receivedInvocation = false
    private static let maxRecords = 200
    private static let maxStreamCharacters = 32_768
    private static let maxTotalCharacters = 1_048_576

    private struct Record {
        let invocationID: Int
        let id = UUID()
        let timestamp = Date()
        let root: URL
        let arguments: [String]
        var stdout = ""
        var stderr = ""
        var progress: String?
        var truncated = false
        var state: GitConsoleEntryState = .running
        var exitCode: Int32 = 0
        var duration: Int?
        var error: String?

        var entry: GitConsoleEntry {
            GitConsoleEntry(id: id, timestamp: timestamp, workingDirectory: root,
                arguments: arguments, output: stdout + stderr, standardOutput: stdout,
                standardError: stderr, exitCode: exitCode, state: state,
                durationMilliseconds: duration, operationTitle: "Git",
                operationErrorMessage: error, progressText: progress, isOutputTruncated: truncated)
        }
    }

    package init(operationID: String = UUID().uuidString) { self.operationID = operationID }

    package func requestCancellation() { lock.withLock { cancelled = true } }
    package var isCancellationRequested: Bool { lock.withLock { cancelled } }
    package var hasInvocations: Bool { lock.withLock { receivedInvocation } }

    package func receive(_ event: GitExecutionEvent) {
        guard event.operationId == operationID, let invocationID = event.invocationId else { return }
        lock.withLock {
            if event.type == "started", let root = event.workingDirectory, let arguments = event.arguments {
                receivedInvocation = true
                records.append(Record(invocationID: invocationID, root: URL(fileURLWithPath: root), arguments: arguments))
                if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
                dirty = true
                return
            }
            guard let index = records.lastIndex(where: { $0.invocationID == invocationID }) else { return }
            switch event.type {
            case "output":
                let text = GitConsoleRedactor.redact(event.text ?? "")
                if event.progress == true {
                    records[index].progress = text
                } else {
                    if event.stream == "stderr" { records[index].stderr += text + "\n" }
                    else { records[index].stdout += text + "\n" }
                    records[index].progress = nil
                }
                records[index].truncated = records[index].truncated || event.truncated == true
                if records[index].stdout.count > Self.maxStreamCharacters {
                    records[index].stdout = String(records[index].stdout.suffix(Self.maxStreamCharacters))
                    records[index].truncated = true
                }
                if records[index].stderr.count > Self.maxStreamCharacters {
                    records[index].stderr = String(records[index].stderr.suffix(Self.maxStreamCharacters))
                    records[index].truncated = true
                }
                while records.count > 1 && records.reduce(0, { $0 + $1.stdout.count + $1.stderr.count }) > Self.maxTotalCharacters {
                    records.removeFirst()
                }
            case "finished":
                records[index].state = event.exitCode == nil ? .unconfirmed : .completed
                records[index].exitCode = event.exitCode ?? -1
                records[index].duration = event.durationMilliseconds
                records[index].error = event.error.map { [$0.message, $0.details].compactMap { $0 }.joined(separator: "\n") }
                records[index].progress = nil
            default: return
            }
            dirty = true
        }
    }

    /// Snapshot frequency is owned by the UI coordinator, not native output rate.
    package func drainSnapshot() -> [GitConsoleEntry]? {
        lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return records.map(\.entry)
        }
    }
}
