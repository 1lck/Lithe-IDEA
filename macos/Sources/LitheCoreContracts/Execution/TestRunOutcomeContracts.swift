import Foundation

/// How a test process ended, as the host observed it.
public enum TestRunTermination: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
}

/// The breadth the host asked to run; Core never reads selector syntax.
public enum TestRunScopeKind: String, Codable, Equatable, Sendable {
    case workspace, project, suite, `case`
}

/// Counts from the provider's decoded results.
public struct TestRunSummaryCounts: Codable, Equatable, Sendable {
    public let total: Int
    public let passed: Int
    public let failed: Int
    public let errors: Int
    public let skipped: Int

    public init(total: Int, passed: Int, failed: Int, errors: Int, skipped: Int) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.errors = errors
        self.skipped = skipped
    }
}

/// `build.resolveTestRunOutcome`'s tool-neutral verdict.
public enum TestRunOutcome: String, Codable, Equatable, Sendable {
    case passed
    case testsFailed
    case exitedWithError
    case noTestsMatched
    case noTestsFound
    case timedOut
    case cancelled
}

public struct TestRunVerdict: Codable, Equatable, Sendable {
    public let outcome: TestRunOutcome
    public let success: Bool
    public let exitCode: Int32?
}

/// What a run replaces in the stored test history: exact result ids and id
/// prefixes. The provider adapter builds it; Core only compares strings.
public struct TestOutcomeMergeScope: Codable, Equatable, Sendable {
    public var ids: [String]
    public var prefixes: [String]

    public init(ids: [String] = [], prefixes: [String] = []) {
        self.ids = ids
        self.prefixes = prefixes
    }
}

/// One merged result: its position in the `previous` or `incoming` input.
public struct TestOutcomeMergeEntry: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case previous, incoming }
    public let source: Source
    public let index: Int
}

/// Reduces a finished test run to the verdict both platforms show.
public protocol TestRunOutcomeResolving: Sendable {
    /// `build.mergeTestOutcomes`: which stored and which reported results
    /// make up the new history, in display order.
    func mergeTestOutcomes(
        previous: [String],
        incoming: [String],
        scope: TestOutcomeMergeScope
    ) throws -> [TestOutcomeMergeEntry]

    func resolveTestRunOutcome(
        termination: TestRunTermination,
        scope: TestRunScopeKind,
        summary: TestRunSummaryCounts?
    ) throws -> TestRunVerdict
}

/// A JSON command transport to Rust Core, shared by the app bridge and tests
/// that link the same Core library.
public protocol TestRunOutcomeCoreCommandExecuting: TestRunOutcomeResolving {
    func executeTestRunOutcomeCommand<Payload: Encodable, Response: Decodable>(
        _ command: String,
        payload: Payload
    ) throws -> Response
}

public extension TestRunOutcomeCoreCommandExecuting {
    func resolveTestRunOutcome(
        termination: TestRunTermination,
        scope: TestRunScopeKind,
        summary: TestRunSummaryCounts?
    ) throws -> TestRunVerdict {
        let encoded: ResolveTestRunOutcomeTermination
        switch termination {
        case .exited(let code): encoded = ResolveTestRunOutcomeTermination(kind: "exited", exitCode: code)
        case .timedOut: encoded = ResolveTestRunOutcomeTermination(kind: "timedOut", exitCode: nil)
        case .cancelled: encoded = ResolveTestRunOutcomeTermination(kind: "cancelled", exitCode: nil)
        }
        return try executeTestRunOutcomeCommand(
            "build.resolveTestRunOutcome",
            payload: ResolveTestRunOutcomePayload(termination: encoded, scope: scope, summary: summary)
        )
    }
}

public extension TestRunOutcomeCoreCommandExecuting {
    func mergeTestOutcomes(
        previous: [String],
        incoming: [String],
        scope: TestOutcomeMergeScope
    ) throws -> [TestOutcomeMergeEntry] {
        let response: MergeTestOutcomesResponse = try executeTestRunOutcomeCommand(
            "build.mergeTestOutcomes",
            payload: MergeTestOutcomesPayload(previous: previous, incoming: incoming, scope: scope)
        )
        return response.entries
    }
}

private struct MergeTestOutcomesPayload: Encodable {
    let previous: [String]
    let incoming: [String]
    let scope: TestOutcomeMergeScope
}

private struct MergeTestOutcomesResponse: Decodable {
    let entries: [TestOutcomeMergeEntry]
}

private struct ResolveTestRunOutcomeTermination: Encodable {
    let kind: String
    let exitCode: Int32?
}

private struct ResolveTestRunOutcomePayload: Encodable {
    let termination: ResolveTestRunOutcomeTermination
    let scope: TestRunScopeKind
    let summary: TestRunSummaryCounts?
}
