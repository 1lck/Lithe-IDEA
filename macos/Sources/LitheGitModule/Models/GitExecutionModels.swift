import Foundation
import LitheModuleAPI

/// Versioned Core diagnostics. Absolute directories are native display context.
package struct GitExecutionEvent: Decodable, Sendable {
    package let operationId: String
    package let type: String
    package var source: GitExecutionSource?
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
    package var expectedExit: Bool?
    package var exitCode: Int32?
    package var durationMilliseconds: Int?
    package var error: Failure?
    /// `requestStarted`: the console journal budget Core defines for every host.
    package var retention: GitJournalRetention?
    /// `finished`: the record's final state, decided by Core.
    package var state: String?
    /// `requestFinished`: records of this request whose exit was never observed.
    package var unconfirmedInvocations: [Int]?
    /// `requestFinished`: the failure needs its own record because no Git process started.
    package var failureRecord: Bool?

    package struct Failure: Decodable, Sendable {
        package let code: String
        package let message: String
        package var details: String?

        /// A request that a newer request or the user superseded. It is not a Git failure.
        package var isCancellation: Bool { code == "cancelled" }
    }
}

/// Console journal budget from Core, in character counts.
package struct GitJournalRetention: Decodable, Equatable, Sendable {
    package let maxRecords: Int
    package let maxRecordOutputCharacters: Int
    package let maxRecordOutputLines: Int
    package let maxTotalOutputCharacters: Int
}

/// The lock protects synchronous bridge delivery and cancellation across the
/// worker/UI boundary. Only bounded snapshots cross onto the main actor.
package final class GitExecutionContext: @unchecked Sendable {
    @TaskLocal package static var current: GitExecutionContext?
    package let operationID: String
    package let source: GitExecutionSource
    /// The user action that started this execution, kept across detached hops.
    package let action: UserAction?
    private let lock = NSLock()
    private var cancelled = false
    private var records: [Record] = []
    private var dirty = false
    private var challenges: [GitAuthenticationChallenge] = []
    private var requestRoot: URL?
    private var requestInvocationID: UUID?
    private var omittedHistory = false
    /// Core's budget, learned from `requestStarted`; nothing is trimmed before it arrives.
    private var retention: GitJournalRetention?

    private struct Record {
        let invocationID: Int
        let id = UUID()
        let timestamp = Date()
        let sequence = GitConsoleSequenceCounter.shared.next()
        let root: URL
        let arguments: [String]
        var source: GitExecutionSource = .unknown
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
        var expectedExit = false
        var exitCode: Int32 = 0
        var duration: Int?
        var error: String?

        mutating func appendOutput(_ text: String, stream: GitConsoleOutputStream, retention: GitJournalRetention?) {
            // Bound both text storage and rendered rows, including empty lines.
            guard let retention else {
                lines.append(GitConsoleOutputLine(stream: stream, text: text))
                lineCharacters += text.count + 1
                return
            }
            let retained = String(text.suffix(retention.maxRecordOutputCharacters - 1))
            lines.append(GitConsoleOutputLine(stream: stream, text: retained))
            lineCharacters += retained.count + 1
            truncated = truncated || retained.count < text.count
            while lines.count > 1 && (lineCharacters > retention.maxRecordOutputCharacters
                || lines.count > retention.maxRecordOutputLines) {
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
                displayArguments: displayArguments, globalArguments: globalArguments, source: source, expectedExit: expectedExit, sequence: sequence)
        }
    }

    package init(operationID: String = UUID().uuidString, source: GitExecutionSource = .unknown,
        action: UserAction? = UserActionContext.current, retention: GitJournalRetention? = nil) {
        self.retention = retention
        self.operationID = operationID
        self.source = source
        self.action = action
    }

    /// The `op` Core gives this execution's request and Git process records:
    /// the action's operation unless a background poller owns the request.
    package var traceOperationID: String {
        source == .background ? operationID : ((action ?? UserActionContext.current)?.operationID ?? operationID)
    }

    package func requestCancellation() { lock.withLock { cancelled = true } }
    package var isCancellationRequested: Bool { lock.withLock { cancelled } }
    package var hasOmittedHistory: Bool { lock.withLock { omittedHistory } }
    package var hasEntries: Bool { lock.withLock { !records.isEmpty } }

    package func receive(_ event: GitExecutionEvent, at root: URL? = nil) {
        guard event.operationId == operationID else { return }
        lock.withLock { receiveLocked(event, at: root) }
    }

    /// Called with the lock held so each event publishes an atomic snapshot.
    private func receiveLocked(_ event: GitExecutionEvent, at root: URL?) {
        if event.type == "requestStarted" {
            if let retention = event.retention { self.retention = retention }
            requestRoot = root ?? event.workingDirectory.map { URL(fileURLWithPath: $0) }
            requestInvocationID = nil
            return
        }
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
            defer { requestRoot = nil; requestInvocationID = nil }
            challenges.removeAll()
            let unconfirmed = Set(event.unconfirmedInvocations ?? [])
            for index in records.indices where unconfirmed.contains(records[index].invocationID) {
                records[index].state = .unconfirmed
                dirty = true
            }
            if let error = event.error {
                let message = [error.message, error.details].compactMap { $0 }.joined(separator: "\n")
                if let index = records.lastIndex(where: { $0.id == requestInvocationID }) {
                    records[index].error = message
                    dirty = true
                } else if let root = requestRoot, event.failureRecord == true {
                    // A context can span several Core requests. Keep a preflight
                    // failure separate from an earlier request's executed command.
                    // Core decides which failures need a record of their own.
                    appendRecord(Record(invocationID: -1, root: root, arguments: [],
                        source: source, state: .unconfirmed, exitCode: -1, error: message))
                }
            }
            return
        }
        if event.type == "remoteResult", let index = records.lastIndex(where: { event.invocationId == nil || $0.invocationID == event.invocationId }) {
            records[index].remoteResult = remoteOutcome(for: event)
            if let error = event.error { records[index].error = error.message }
            dirty = true
            return
        }
        guard let invocationID = event.invocationId else { return }
        if event.type == "started", let root = event.workingDirectory, let arguments = event.arguments {
            let record = Record(invocationID: invocationID, root: URL(fileURLWithPath: root), arguments: arguments,
                source: event.source ?? source, executable: event.executable, temporaryConfig: event.temporaryConfig ?? [],
                displayArguments: event.displayArguments, globalArguments: event.globalArguments)
            requestInvocationID = record.id
            appendRecord(record)
            return
        }
        guard let index = records.lastIndex(where: { $0.invocationID == invocationID }) else { return }
        switch event.type {
        case "output":
            records[index].phase = event.progressDetails ?? records[index].phase
            // Core redacts event text once; the host never scrubs it again.
            let text = event.text ?? ""
            if event.progress == true {
                records[index].progress = text
            } else {
                if event.stream == "stderr" { records[index].stderr += text + "\n" }
                else { records[index].stdout += text + "\n" }
                records[index].appendOutput(text, stream: event.stream == "stderr" ? .standardError : .standardOutput, retention: retention)
                records[index].progress = nil
            }
            records[index].truncated = records[index].truncated || event.truncated == true
            if let retention {
                if records[index].stdout.count > retention.maxRecordOutputCharacters {
                    records[index].stdout = String(records[index].stdout.suffix(retention.maxRecordOutputCharacters))
                    records[index].truncated = true
                }
                if records[index].stderr.count > retention.maxRecordOutputCharacters {
                    records[index].stderr = String(records[index].stderr.suffix(retention.maxRecordOutputCharacters))
                    records[index].truncated = true
                }
                while records.count > 1 && records.reduce(0, { $0 + $1.stdout.count + $1.stderr.count + $1.lineCharacters }) > retention.maxTotalOutputCharacters {
                    omittedHistory = true
                    records.removeFirst()
                }
            }
        case "finished":
            records[index].state = event.state == "completed" ? .completed : .unconfirmed
            records[index].exitCode = event.exitCode ?? -1
            records[index].expectedExit = event.expectedExit ?? false
            records[index].duration = event.durationMilliseconds
            records[index].error = event.error.map { [$0.message, $0.details].compactMap { $0 }.joined(separator: "\n") }
            records[index].progress = nil
        default: return
        }
        dirty = true
    }

    private func appendRecord(_ record: Record) {
        records.append(record)
        if let maxRecords = retention?.maxRecords, records.count > maxRecords { omittedHistory = true; records.removeFirst(records.count - maxRecords) }
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
            referencesAvailable: event.referencesAvailable ?? true,
            referenceCountsKnown: (event.updatedReferenceCount != nil || event.updatedReferences != nil)
                && (event.deletedReferenceCount != nil || event.deletedReferences != nil))
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
    package var referenceCountsKnown = true
}

/// Shared start order includes executions in other repositories and feature contexts.
private final class GitConsoleSequenceCounter: @unchecked Sendable {
    static let shared = GitConsoleSequenceCounter()
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 { lock.withLock { value &+= 1; return value } }
}
