import Foundation

/// Versioned Core diagnostics. Absolute directories are native display context.
package struct GitExecutionEvent: Decodable, Sendable {
    package let operationId: String
    package let type: String
    package var executable: String?
    package var temporaryConfig: [[String]]?
    package var displayArguments: [String]?
    package var globalArguments: [String]?
    package var progressDetails: GitPhaseProgress?
    package var requestId: String?
    package var prompt: String?
    package var secret: Bool?
    package var attempt: Int?
    package var retry: Bool?
    package var remote: String?
    package var updatedReferenceCount: Int?
    package var deletedReferenceCount: Int?
    package var referencesTruncated: Bool?
    package var referencesAvailable: Bool?
    package var updatedReferences: [String]?
    package var deletedReferences: [String]?
    package var succeeded: Bool?
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
    private var challenges: [GitAuthenticationChallenge] = []
    private var receivedInvocation = false
    private static let maxRecords = 200
    private static let maxStreamCharacters = 32_768
    private static let maxOutputLines = 2_000
    private static let maxTotalCharacters = 1_048_576

    private struct Record {
        let invocationID: Int
        let id = UUID()
        let timestamp = Date()
        let root: URL
        let arguments: [String]
        var executable: String?
        var temporaryConfig: [[String]] = []
        var displayArguments: [String]?
        var globalArguments: [String]?
        var phase: GitPhaseProgress?
        var remoteResult: GitRemoteOutcome?
        var stdout = ""
        var stderr = ""
        var lines: [GitConsoleOutputLine] = []
        var lineCharacters = 0
        var progress: String?
        var truncated = false
        var state: GitConsoleEntryState = .running
        var exitCode: Int32 = 0
        var duration: Int?
        var error: String?

        mutating func appendOutput(_ text: String, stream: GitConsoleOutputStream) {
            // Bound both text storage and rendered rows, including empty lines.
            let retained = String(text.suffix(GitExecutionContext.maxStreamCharacters - 1))
            lines.append(GitConsoleOutputLine(stream: stream, text: retained))
            lineCharacters += retained.count + 1
            truncated = truncated || retained.count < text.count
            while lines.count > 1 && (lineCharacters > GitExecutionContext.maxStreamCharacters
                || lines.count > GitExecutionContext.maxOutputLines) {
                lineCharacters -= lines.removeFirst().text.count + 1
                truncated = true
            }
        }

        var entry: GitConsoleEntry {
            GitConsoleEntry(id: id, timestamp: timestamp, workingDirectory: root,
                arguments: arguments, output: lines.map { $0.text + "\n" }.joined(), standardOutput: stdout,
                standardError: stderr, orderedOutputLines: lines, exitCode: exitCode, state: state,
                durationMilliseconds: duration, operationTitle: "Git",
                operationErrorMessage: error, progressText: progress, isOutputTruncated: truncated,
                executable: executable, temporaryConfig: temporaryConfig, phase: phase, remoteResult: remoteResult,
                displayArguments: displayArguments, globalArguments: globalArguments)
        }
    }

    package init(operationID: String = UUID().uuidString) { self.operationID = operationID }

    package func requestCancellation() { lock.withLock { cancelled = true } }
    package var isCancellationRequested: Bool { lock.withLock { cancelled } }
    package var hasInvocations: Bool { lock.withLock { receivedInvocation } }

    package func receive(_ event: GitExecutionEvent) {
        guard event.operationId == operationID else { return }
        lock.withLock { receiveLocked(event) }
    }

    /// Called with the lock held so each event publishes an atomic snapshot.
    private func receiveLocked(_ event: GitExecutionEvent) {
        if event.type == "authentication", let id = event.requestId {
            let challenge = GitAuthenticationChallenge(
                id: id, operationID: operationID,
                prompt: event.prompt ?? "Git authentication",
                secret: event.secret ?? true,
                attempt: event.attempt ?? 1,
                retry: event.retry ?? false)
            challenges.append(challenge)
            return
        }
        if event.type == "requestFinished" {
            challenges.removeAll()
            for index in records.indices where records[index].state == .running {
                records[index].state = .unconfirmed
                dirty = true
            }
            if let error = event.error, let index = records.indices.last {
                records[index].error = [error.message, error.details].compactMap { $0 }.joined(separator: "\n")
                dirty = true
            }
            return
        }
        if event.type == "remoteResult", let index = records.indices.last {
            records[index].remoteResult = remoteOutcome(for: event)
            if let error = event.error { records[index].error = error.message }
            dirty = true
            return
        }
        guard let invocationID = event.invocationId else { return }
        if event.type == "started", let root = event.workingDirectory, let arguments = event.arguments {
            receivedInvocation = true
            records.append(Record(invocationID: invocationID, root: URL(fileURLWithPath: root), arguments: arguments,
                executable: event.executable, temporaryConfig: event.temporaryConfig ?? [],
                displayArguments: event.displayArguments, globalArguments: event.globalArguments))
            if records.count > Self.maxRecords { records.removeFirst(records.count - Self.maxRecords) }
            dirty = true
            return
        }
        guard let index = records.lastIndex(where: { $0.invocationID == invocationID }) else { return }
        switch event.type {
        case "output":
            records[index].phase = event.progressDetails ?? records[index].phase
            let text = GitConsoleRedactor.redact(event.text ?? "")
            if event.progress == true {
                records[index].progress = text
            } else {
                if event.stream == "stderr" { records[index].stderr += text + "\n" }
                else { records[index].stdout += text + "\n" }
                records[index].appendOutput(text, stream: event.stream == "stderr" ? .standardError : .standardOutput)
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
            while records.count > 1 && records.reduce(0, { $0 + $1.stdout.count + $1.stderr.count + $1.lineCharacters }) > Self.maxTotalCharacters {
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

    private func remoteOutcome(for event: GitExecutionEvent) -> GitRemoteOutcome {
        // Resolve collection defaults before counts to keep Swift 6.2 type
        // inference bounded and preserve counts supplied for truncated lists.
        let updatedReferences: [String] = event.updatedReferences ?? []
        let deletedReferences: [String] = event.deletedReferences ?? []
        let updatedCount: Int = event.updatedReferenceCount ?? updatedReferences.count
        let deletedCount: Int = event.deletedReferenceCount ?? deletedReferences.count
        return GitRemoteOutcome(
            remote: event.remote ?? "", succeeded: event.succeeded ?? false,
            updatedReferences: updatedReferences, deletedReferences: deletedReferences,
            updatedCount: updatedCount, deletedCount: deletedCount,
            truncated: event.referencesTruncated ?? false,
            referencesAvailable: event.referencesAvailable ?? true)
    }

    package func drainChallenges() -> [GitAuthenticationChallenge] {
        lock.withLock { defer { challenges.removeAll() }; return challenges }
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

package struct GitPhaseProgress: Decodable, Equatable, Sendable {
    package let stage: String
    package let percent: Int?
    package let completed: Int?
    package let total: Int?
}
package struct GitRemoteOutcome: Equatable, Sendable {
    package let remote: String
    package let succeeded: Bool
    package let updatedReferences: [String]
    package let deletedReferences: [String]
    package var updatedCount = 0
    package var deletedCount = 0
    package var truncated = false
    package var referencesAvailable = true
}
