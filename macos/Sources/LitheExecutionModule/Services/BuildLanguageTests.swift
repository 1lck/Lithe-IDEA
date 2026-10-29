import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// Generic handoff between the language test UI and a build provider's operation.
package struct LanguageTestBackendResult: Sendable {
    package let exitCode: Int32
    package let reports: [BuildTestResults]
    package let references: [BuildTestCaseKey: BuildTestReference]

    package init(exitCode: Int32, reports: [BuildTestResults], references: [BuildTestCaseKey: BuildTestReference] = [:]) {
        self.exitCode = exitCode; self.reports = reports; self.references = references
    }
}

package struct BuildTestCaseKey: Hashable, Sendable {
    package let project: String?
    package let suite: String
    package let testCase: String
    package init(project: String?, suite: String, testCase: String) { self.project = project; self.suite = suite; self.testCase = testCase }
    package init(_ test: BuildTestResults.TestCase) { project = test.project; suite = test.suite; testCase = test.name }
}

@MainActor
package extension BuildSystemService {
    /// Resolves ownership from current model boundaries, never a build descriptor
    /// or a test file's basename. A missing/stale provider remains unavailable.
    func languageTestEntries(selectorKind: String, fileURL: URL?, workspace: URL) -> [BuildSystemEntry] {
        guard workspace.standardizedFileURL == workspaceURL else { return [] }
        let candidates = entries.filter {
            $0.declaration.testSelectorKinds.contains(selectorKind)
                && $0.modelState == .loaded && !$0.isReloadRequired && $0.model != nil
        }
        guard let fileURL else { return candidates.sorted { $0.instance.root < $1.instance.root } }
        let path = fileURL.standardizedFileURL.path
        return candidates.filter { entry in
            entry.model?.projects.contains { project in
                let directory = workspace.appendingPathComponent(project.path).standardizedFileURL.path
                return path == directory || path.hasPrefix(directory + "/")
            } == true
        }.sorted { $0.instance.root.count > $1.instance.root.count }.prefix(1).map { $0 }
    }

    func languageTestProject(in entry: BuildSystemEntry, fileURL: URL?, workspace: URL) -> BuildSelection? {
        guard let fileURL else { return nil }
        let path = fileURL.standardizedFileURL.path
        return entry.model?.projects.filter { project in
            let directory = workspace.appendingPathComponent(project.path).standardizedFileURL.path
            return path == directory || path.hasPrefix(directory + "/")
        }.sorted { $0.path.count > $1.path.count }.first.map(BuildSelection.init(project:))
    }

    func performLanguageTests(selectorKind: String, fileURL: URL?, workspace: URL, title: String,
                              isCurrent: @escaping @MainActor () -> Bool,
                              beforePreparing: @escaping @MainActor () async throws -> Void = {},
                              prepareSelectors: @escaping @MainActor () async throws -> [String],
                              output: @escaping @MainActor (String) -> Void,
                              process: @escaping @MainActor (Int32?) -> Void = { _ in }) async throws -> LanguageTestBackendResult {
        var previousOperation = operation?.id
        try await beforePreparing()
        guard isCurrent(), operation?.id == previousOperation, !Task.isCancelled else { throw CancellationError() }
        try await prepareLanguageTestModels(selectorKind: selectorKind, workspace: workspace)
        let revision = inputRevision
        let selectors = try await prepareSelectors()
        guard isCurrent(), inputRevision == revision, operation?.id == previousOperation,
              !Task.isCancelled else { throw CancellationError() }
        let entries = languageTestEntries(selectorKind: selectorKind, fileURL: fileURL, workspace: workspace)
        guard !entries.isEmpty else { throw BuildSystemServiceError(L10n.string("Load the current build model and enable its provider before running this configuration.")) }
        var reports: [BuildTestResults] = []
        var references: [BuildTestCaseKey: BuildTestReference] = [:]
        var exitCode: Int32 = 0
        var completedOutput = ""
        for entry in entries {
            try Task.checkCancellation()
            guard isCurrent(), inputRevision == revision, operation?.id == previousOperation else { throw CancellationError() }
            let request = BuildTestRequest(project: languageTestProject(in: entry, fileURL: fileURL, workspace: workspace),
                projects: entry.model?.projects.map(\.path) ?? [], selectorKind: selectorKind, selectors: selectors)
            var currentOutput = ""
            let prefix = completedOutput
            let result = try await performLanguageTests(entry.id, request: request, title: title) { text in
                currentOutput = text
                output(prefix + text)
            } process: { process($0) }
            previousOperation = operation?.id
            reports += result.reports
            for (key, reference) in result.references {
                guard references[key] == nil || references[key] == reference else {
                    throw BuildSystemServiceError(L10n.string("The build provider returned an invalid launch plan."))
                }
                references[key] = reference
            }
            completedOutput += currentOutput
            if result.exitCode != 0 { exitCode = result.exitCode }
        }
        guard isCurrent(), inputRevision == revision, !Task.isCancelled else { throw CancellationError() }
        return LanguageTestBackendResult(exitCode: exitCode, reports: reports, references: references)
    }

    /// Report-only items need no guessed source association. Membership and
    /// backend availability are resolved from current declarations and models.
    func performLanguageTests(reference: BuildTestReference, workspace: URL, title: String,
                              isCurrent: @escaping @MainActor () -> Bool = { true },
                              beforePreparing: @escaping @MainActor () async throws -> Void = {},
                              output: @escaping @MainActor (String) -> Void,
                              process: @escaping @MainActor (Int32?) -> Void) async throws -> LanguageTestBackendResult {
        let previousOperation = operation?.id
        try await beforePreparing()
        try await prepareLanguageTestModels(reference: reference, workspace: workspace)
        let revision = inputRevision
        guard isCurrent(), !Task.isCancelled, operation?.id == previousOperation, workspace.standardizedFileURL == workspaceURL,
              let entry = entries.first(where: { $0.instance.pluginID == reference.pluginID && $0.instance.buildSystemID == reference.buildSystemID
                && $0.instance.root == reference.root }), entry.modelState == .loaded, !entry.isReloadRequired,
              let project = entry.model?.projects.first(where: { $0.id == reference.projectID }) else {
            throw BuildSystemServiceError(L10n.string("Load the current build model and enable its provider before running this configuration."))
        }
        let result = try await performLanguageTests(entry.id, request: BuildTestRequest(project: BuildSelection(project: project),
            suite: reference.suite, testCase: reference.testCase), title: title, output: output, process: process)
        guard isCurrent(), inputRevision == revision, !Task.isCancelled else { throw CancellationError() }
        return result
    }

    /// Subscriptions exist only for this awaited operation. Stop, replacement,
    /// plugin withdrawal and workspace reset all settle through runEnded.
    func performLanguageTests(_ entryID: String, request: BuildTestRequest, title: String,
                              output: @escaping @MainActor (String) -> Void,
                              process: @escaping @MainActor (Int32?) -> Void = { _ in }) async throws -> LanguageTestBackendResult {
        try Task.checkCancellation()
        let (events, continuation) = AsyncStream.makeStream(of: (BuildRunEnd, BuildTestResults?).self)
        let completion = runEnded.sink { [weak self] ended in
            continuation.yield((ended, self?.testResults))
        }
        defer { completion.cancel(); continuation.finish() }
        guard let entry = entry(entryID), let id = runTests(entryID, request: request, title: title) else { throw CancellationError() }
        let progress = $operation.sink { snapshot in
            guard let snapshot, snapshot.id == id else { return }
            output(snapshot.output)
            process(snapshot.processID)
        }
        defer { progress.cancel(); cancelRun(id) }
        return try await withTaskCancellationHandler {
            for await (ended, results) in events where ended.runID == id {
                try Task.checkCancellation()
                guard operation?.id == id else { throw CancellationError() }
                switch ended.state {
                case .cancelled: throw CancellationError()
                case .failed(let message) where ended.exitCode == nil:
                    throw BuildSystemServiceError(message)
                default:
                    var references: [BuildTestCaseKey: BuildTestReference] = [:]
                    for test in results?.tests ?? [] {
                        guard let project = entry.model?.projects.first(where: { $0.path == test.project }) else { continue }
                        references[BuildTestCaseKey(test)] = BuildTestReference(pluginID: entry.instance.pluginID,
                            buildSystemID: entry.instance.buildSystemID, root: entry.instance.root,
                            projectID: project.id, suite: test.suite, testCase: test.name)
                    }
                    return LanguageTestBackendResult(exitCode: ended.exitCode ?? -1, reports: results.map { [$0] } ?? [], references: references)
                }
            }
            throw CancellationError()
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelRun(id) }
        }
    }
}
