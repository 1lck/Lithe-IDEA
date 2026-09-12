import Foundation

/// Versioned Core diagnostics. Absolute directories are native display context.
package struct GitExecutionEvent: Decodable, Sendable {
    package let operationId: String
    package let type: String
    package var executable: String?
    package var temporaryConfig: [[String]]?
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
    private static let maxTotalCharacters = 1_048_576

    private struct Record {
        let invocationID: Int
        let id = UUID()
        let timestamp = Date()
        let root: URL
        let arguments: [String]
        var executable: String?
        var temporaryConfig: [[String]] = []
        var phase: GitPhaseProgress?
        var remoteResult: GitRemoteOutcome?
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
                operationErrorMessage: error, progressText: progress, isOutputTruncated: truncated,
                executable: executable, temporaryConfig: temporaryConfig, phase: phase, remoteResult: remoteResult)
        }
    }

    package init(operationID: String = UUID().uuidString) { self.operationID = operationID }

    package func requestCancellation() { lock.withLock { cancelled = true } }
    package var isCancellationRequested: Bool { lock.withLock { cancelled } }
    package var hasInvocations: Bool { lock.withLock { receivedInvocation } }

    package func receive(_ event: GitExecutionEvent) {
        guard event.operationId == operationID else { return }
        lock.withLock {
            if event.type == "authentication", let id = event.requestId {
                challenges.append(.init(id: id, operationID: operationID, prompt: event.prompt ?? "Git authentication", secret: event.secret ?? true, attempt: event.attempt ?? 1, retry: event.retry ?? false))
                return
            }
            if event.type == "requestFinished" { challenges.removeAll(); return }
            if event.type == "remoteResult", let index = records.indices.last {
                records[index].remoteResult = .init(remote: event.remote ?? "", succeeded: event.succeeded ?? false,
                    updatedReferences: event.updatedReferences ?? [], deletedReferences: event.deletedReferences ?? [],
                    updatedCount: event.updatedReferenceCount ?? event.updatedReferences?.count ?? 0, deletedCount: event.deletedReferenceCount ?? event.deletedReferences?.count ?? 0, truncated: event.referencesTruncated ?? false, referencesAvailable: event.referencesAvailable ?? true)
                if let error = event.error { records[index].error = error.message }
                dirty = true
                return
            }
            guard let invocationID = event.invocationId else { return }
            if event.type == "started", let root = event.workingDirectory, let arguments = event.arguments {
                receivedInvocation = true
                records.append(Record(invocationID: invocationID, root: URL(fileURLWithPath: root), arguments: arguments,
                    executable: event.executable, temporaryConfig: event.temporaryConfig ?? []))
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
