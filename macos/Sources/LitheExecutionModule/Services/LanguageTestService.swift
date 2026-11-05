import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

package enum LanguageTestRunState: Equatable, Sendable {
    case idle
    case running
    case passed
    case failed(exitCode: Int32)
    case timedOut
    case cancelled
}

@MainActor
package final class LanguageTestService: ObservableObject {
    @Published package private(set) var itemsByProviderID: [String: [LanguageTestItem]] = [:]
    @Published package private(set) var state: LanguageTestRunState = .idle
    @Published package private(set) var activePlan: LanguageTestPlan?
    @Published package private(set) var results: BuildTestResults?
    /// Backend coverage replaces only completed scopes; unrelated editor markers survive.
    @Published package private(set) var testOutcomesByProviderID: [String: [BuildTestResults.TestCase]] = [:]
    package private(set) var resultReferences: [BuildTestCaseKey: BuildTestReference] = [:]
    private var resultsWorkspaceURL: URL?
    @Published package private(set) var output = ""
    @Published package private(set) var errorMessage: String?
    @Published package private(set) var runID: UUID?
    @Published package private(set) var processID: Int32?

    private let outcomeResolver: any TestRunOutcomeResolving
    private let catalog: LanguageProviderCatalog
    private let registry: LanguageTestProviderRegistry
    private let executableResolver: any RunExecutableResolving
    private let processFactory: () -> any StreamingProcess
    private let extensionRequiredLanguageIDs: Set<String>
    private var process: (any StreamingProcess)?
    private var extensionSession: (any LanguageExecutionSession)?
    private var languageTestExtensions: [String: RegisteredLanguageTestExtension] = [:]
    private var activeOperationID: String?
    private var timedOutOperationID: String?
    private var activeWorkspaceURL: URL?
    private var backendTask: Task<Void, Never>?
    private var lastBackendRun: (@MainActor () -> Void)?
    private var lastRun: LastRun?
    private let maximumOutputCharacters = 400_000
    private static let javaTestTimeoutMilliseconds = 120_000

    package init(
        outcomeResolver: any TestRunOutcomeResolving,
        catalog: LanguageProviderCatalog = .compatibilityFallback,
        registry: LanguageTestProviderRegistry? = nil,
        executableResolver: any RunExecutableResolving,
        processFactory: @escaping () -> any StreamingProcess,
        extensionRequiredLanguageIDs: Set<String> = []
    ) {
        self.outcomeResolver = outcomeResolver
        self.catalog = catalog
        self.registry = registry ?? .standard(catalog: catalog)
        self.executableResolver = executableResolver
        self.processFactory = processFactory
        self.extensionRequiredLanguageIDs = extensionRequiredLanguageIDs
    }

    package func testOutcomes(for providerID: String) -> [BuildTestResults.TestCase] {
        testOutcomesByProviderID[providerID] ?? []
    }

    package var isRunning: Bool { state == .running }
    package var canRerun: Bool { (lastRun != nil || lastBackendRun != nil) && !isRunning }

    package func hasRun(providerID: String, scope: LanguageTestScope) -> Bool {
        lastRun?.providerID == providerID && lastRun?.scope == scope
    }

    @discardableResult
    package func registerLanguageTestExtension(
        _ provider: any LanguageTestExtensionProviding,
        support: LanguageSupportDeclaration
    ) -> Bool {
        guard provider.languageID == support.id,
              support.testingModuleID != nil else { return false }
        languageTestExtensions[support.id] = RegisteredLanguageTestExtension(
            support: support,
            provider: provider
        )
        return true
    }

    package func unregisterLanguageTestExtension(languageID: String) {
        if activePlan?.providerID == languageID { stop() }
        languageTestExtensions[languageID] = nil
        itemsByProviderID[languageID] = nil
    }

    package func discover(workspaceURL: URL, files: [URL]) {
        var discovered: [String: [LanguageTestItem]] = [:]
        let context = LanguageTestContext(
            workspaceURL: workspaceURL,
            projectFiles: files
        )
        for descriptor in catalog.descriptors where descriptor.capabilities.contains(.testing) {
            let items: [LanguageTestItem]
            let extensionProvider = languageTestExtensions[descriptor.id]?.provider
            if extensionRequiredLanguageIDs.contains(descriptor.id), extensionProvider == nil {
                continue
            }
            if let provider = extensionProvider {
                do {
                    items = try provider.discoverTests(for: LanguageTestExtensionDiscoveryRequest(
                        relativeProjectFilePaths: relativeProjectPaths(
                            context.projectFiles,
                            workspaceURL: context.workspaceURL
                        )
                    )).compactMap {
                        testItem(from: $0, providerID: descriptor.id, workspaceURL: context.workspaceURL)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                    continue
                }
            } else {
                guard let provider = registry.provider(id: descriptor.id) else { continue }
                items = provider.discoverTests(context: context)
            }
            if !items.isEmpty { discovered[descriptor.id] = items }
        }
        itemsByProviderID = discovered
    }

    package func replaceDiscoveredItems(
        _ items: [LanguageTestItem],
        providerID: String
    ) {
        if items.isEmpty {
            itemsByProviderID[providerID] = nil
        } else {
            itemsByProviderID[providerID] = items
        }
    }

    @discardableResult
    package func run(
        providerID: String,
        scope: LanguageTestScope,
        workspaceURL: URL,
        projectFiles: [URL] = [],
        options: RunOptions = RunOptions()
    ) -> Bool {
        stop(markCancelled: false)
        lastBackendRun = nil
        runID = nil
        output = ""
        results = nil
        resultReferences = [:]
        resultsWorkspaceURL = nil
        errorMessage = nil
        let root = workspaceURL.standardizedFileURL
        do {
            let plan: LanguageTestPlan
            let extensionProvider = languageTestExtensions[providerID]?.provider
            if extensionRequiredLanguageIDs.contains(providerID), extensionProvider == nil {
                throw LanguageTestPlanError.extensionNotActive(providerID)
            }
            if let extensionProvider {
                let extensionPlan = try extensionProvider.testPlan(for: LanguageTestExtensionRequest(
                    scope: try extensionScope(scope, workspaceURL: root),
                    relativeProjectFilePaths: relativeProjectPaths(
                        projectFiles,
                        workspaceURL: root
                    )
                ))
                plan = LanguageTestPlan(
                    providerID: providerID,
                    label: extensionPlan.label,
                    frameworkID: extensionPlan.frameworkID,
                    launchPlan: Self.sharedLaunchPlan(from: extensionPlan.launchPlan)
                )
            } else {
                guard let provider = registry.provider(id: providerID) else {
                    throw LanguageTestPlanError.unsupportedProvider(providerID)
                }
                plan = try provider.testPlan(
                    scope: scope,
                    context: LanguageTestContext(
                        workspaceURL: root,
                        projectFiles: projectFiles
                    )
                )
            }
            let resolved = try executableResolver.resolve(
                plan.launchPlan,
                projectURL: root,
                options: options
            )
            let workingDirectory = try resolvedWorkingDirectory(
                plan.launchPlan.workingDirectory,
                workspaceURL: root
            )
            let id = UUID()
            runID = id
            let operationID = id.uuidString
            activeOperationID = operationID
            activeWorkspaceURL = root
            let timeoutMarker = LanguageTestTimeoutMarker()
            lastRun = LastRun(
                providerID: providerID,
                scope: scope,
                workspaceURL: root,
                projectFiles: projectFiles,
                options: options
            )
            activePlan = plan
            state = .running
            timedOutOperationID = nil
            append("$ \(resolved.executableURL.lastPathComponent) \(plan.launchPlan.arguments.joined(separator: " "))\n\n")
            let timeoutMilliseconds = Self.testTimeoutMilliseconds(for: plan.frameworkID)
            if let extensionProvider {
                let session = extensionProvider.makeTestExecutionSession()
                configureExtensionSession(
                    session,
                    operationID: operationID,
                    timeoutMarker: timeoutMarker
                )
                extensionSession = session
                try session.start(LanguageExecutionProcessRequest(
                    operationID: operationID,
                    executablePath: resolved.executableURL.path,
                    arguments: plan.launchPlan.arguments,
                    workingDirectory: workingDirectory.path,
                    environment: resolved.environment,
                    timeoutMilliseconds: timeoutMilliseconds
                ))
            } else {
                let process = processFactory()
                configureProcess(
                    process,
                    operationID: operationID,
                    timeoutMarker: timeoutMarker
                )
                self.process = process
                try process.start(ProcessRequest(
                    operationID: operationID,
                    executablePath: resolved.executableURL.path,
                    arguments: plan.launchPlan.arguments,
                    workingDirectory: workingDirectory.path,
                    environment: resolved.environment,
                    timeoutMilliseconds: timeoutMilliseconds
                ))
            }
            return true
        } catch {
            process?.stop()
            process = nil
            extensionSession?.stop()
            extensionSession = nil
            activeOperationID = nil
            processID = nil
            timedOutOperationID = nil
            activePlan = nil
            state = .failed(exitCode: -1)
            errorMessage = error.localizedDescription
            append(error.localizedDescription + "\n")
            return false
        }
    }

    /// Uses an operation-owning backend while preserving the native test UI,
    /// rerun and cancellation lifecycle. The closure resolves fresh facts on rerun.
    package func runUsingBackend(providerID: String, scope: LanguageTestScope, workspaceURL: URL,
                                 label: String,
                                 execute: @escaping @MainActor (@escaping @MainActor (String) -> Void, @escaping @MainActor (Int32?) -> Void) async throws -> LanguageTestBackendResult) {
        stop(markCancelled: false)
        let id = UUID()
        runID = id
        activeOperationID = id.uuidString
        activeWorkspaceURL = workspaceURL.standardizedFileURL
        output = ""; results = nil; resultReferences = [:]; resultsWorkspaceURL = nil; errorMessage = nil
        activePlan = LanguageTestPlan(providerID: providerID, label: label, frameworkID: "build.provider",
            launchPlan: SharedLaunchPlan(executable: .command("build-provider"), arguments: [], workingDirectory: "."))
        lastRun = LastRun(providerID: providerID, scope: scope, workspaceURL: workspaceURL, projectFiles: [], options: RunOptions())
        lastBackendRun = { [weak self] in
            self?.runUsingBackend(providerID: providerID, scope: scope, workspaceURL: workspaceURL, label: label, execute: execute)
        }
        state = .running
        backendTask = Task { [weak self] in
            guard let self else { return }
            defer { if activeOperationID == id.uuidString { activeOperationID = nil; backendTask = nil; processID = nil; activeWorkspaceURL = nil } }
            do {
                let result = try await execute({ [weak self] text in
                    guard let self, activeOperationID == id.uuidString else { return }
                    output = String(text.suffix(maximumOutputCharacters))
                }, { [weak self] pid in
                    guard let self, activeOperationID == id.uuidString else { return }
                    let next = pid.flatMap { $0 > 0 ? $0 : nil }
                    if processID != next { processID = next }
                })
                try Task.checkCancellation()
                guard activeOperationID == id.uuidString else { return }
                let report = BuildTestResults.combining(result.reports)
                results = report
                resultReferences = result.references
                resultsWorkspaceURL = workspaceURL.standardizedFileURL
                // Only the backend can say that a whole suite/project completed.
                // Legacy reports without coverage replace their exact returned cases.
                // Core merges by id; this adapter only names the ids and prefixes.
                let previous = testOutcomesByProviderID[providerID] ?? []
                let coverage = result.reports.flatMap { $0.coverage ?? [] }
                let merged = try outcomeResolver.mergeTestOutcomes(
                    previous: previous.map(\.id),
                    incoming: report.tests.map(\.id),
                    scope: TestOutcomeMergeScope(
                        ids: report.tests.map(\.id),
                        prefixes: coverage.map(Self.coveragePrefix)
                    )
                )
                testOutcomesByProviderID[providerID] = merged.map {
                    $0.source == .previous ? previous[$0.index] : report.tests[$0.index]
                }
                applyVerdict(
                    termination: .exited(result.exitCode),
                    scope: scope,
                    summary: result.reports.isEmpty ? nil : report.summary
                )
            } catch is CancellationError {
                if activeOperationID == id.uuidString { state = .cancelled }
            } catch {
                guard activeOperationID == id.uuidString else { return }
                errorMessage = error.localizedDescription
                append(error.localizedDescription + "\n")
                state = .failed(exitCode: -1)
            }
        }
    }

    /// A coverage scope is a prefix of the ids it completed: a project, one of
    /// its suites, or (with a case name) exactly one test. `TestCase.id` is
    /// length-prefixed per part, so a shorter scope never matches another name.
    private static func coveragePrefix(_ scope: BuildTestResults.Coverage) -> String {
        // A case name is only meaningful inside a suite.
        [scope.project, scope.suite, scope.suite == nil ? nil : scope.testCase]
            .compactMap { $0.map { "\($0.utf8.count):" + $0 } }
            .joined()
    }

    package func sourceURL(for test: BuildTestResults.TestCase) -> URL? {
        guard let root = resultsWorkspaceURL, let path = test.path,
              !path.hasPrefix("/"), !path.contains("\\"),
              !path.split(separator: "/").contains("..") else { return nil }
        return root.appendingPathComponent(path).standardizedFileURL
    }

    package func stop() { stop(markCancelled: true) }

    package func reset() {
        closeRun()
        itemsByProviderID = [:]
        testOutcomesByProviderID = [:]
    }

    /// Dispose the retained run without discarding discovery or editor test markers.
    package func closeRun() {
        stop(markCancelled: false)
        activePlan = nil
        activeWorkspaceURL = nil
        lastRun = nil
        lastBackendRun = nil
        runID = nil
        results = nil
        resultReferences = [:]
        resultsWorkspaceURL = nil
        output = ""
        errorMessage = nil
        state = .idle
    }

    package func clearOutput() {
        output = ""
        results = nil
        resultReferences = [:]
        resultsWorkspaceURL = nil
    }

    @discardableResult
    package func rerun() -> Bool {
        if let lastBackendRun { lastBackendRun(); return true }
        guard let lastRun else { return false }
        return run(
            providerID: lastRun.providerID,
            scope: lastRun.scope,
            workspaceURL: lastRun.workspaceURL,
            projectFiles: lastRun.projectFiles,
            options: lastRun.options
        )
    }

    private func stop(markCancelled: Bool) {
        let wasRunning = state == .running
        activeOperationID = nil
        backendTask?.cancel(); backendTask = nil
        processID = nil
        timedOutOperationID = nil
        activeWorkspaceURL = nil
        process?.stop()
        process = nil
        extensionSession?.stop()
        extensionSession = nil
        if wasRunning && markCancelled { state = .cancelled }
        else if !markCancelled { state = .idle }
    }

    private func resolvedWorkingDirectory(
        _ value: String,
        workspaceURL: URL
    ) throws -> URL {
        let candidate: URL
        if value.isEmpty || value == "." {
            candidate = workspaceURL
        } else if value.hasPrefix("/") {
            candidate = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        } else {
            candidate = workspaceURL.appendingPathComponent(value, isDirectory: true).standardizedFileURL
        }
        guard candidate.path == workspaceURL.path || candidate.path.hasPrefix(workspaceURL.path + "/") else {
            throw LanguageTestPlanError.fileOutsideWorkspace(candidate)
        }
        return candidate
    }

    private func append(_ text: String) {
        output += text
        if output.count > maximumOutputCharacters {
            output.removeFirst(output.count - maximumOutputCharacters)
        }
    }

    private func configureProcess(
        _ process: any StreamingProcess,
        operationID: String,
        timeoutMarker: LanguageTestTimeoutMarker
    ) {
        process.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard self?.activeOperationID == operationID else { return }
                self?.append(chunk)
            }
        }
        process.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                // Let output callbacks already queued by the process drain
                // before taking the final parser snapshot.
                await Task.yield()
                await self?.finish(
                    operationID: operationID,
                    exitCode: exitCode,
                    processTimedOut: timeoutMarker.isTimedOut
                )
            }
        }
        process.onStateChange = { [weak self] event in
            guard event.operationID == operationID else { return }
            let timedOut = event.state == .stopping && event.message == "Process timed out"
            if timedOut { timeoutMarker.mark() }
            Task { @MainActor [weak self] in
                guard let self, self.activeOperationID == operationID else { return }
                if event.state == .running { self.processID = event.processID }
                if timedOut { self.markTimedOut(operationID: operationID) }
            }
        }
    }

    private func configureExtensionSession(
        _ session: any LanguageExecutionSession,
        operationID: String,
        timeoutMarker: LanguageTestTimeoutMarker
    ) {
        session.onOutput = { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard self?.activeOperationID == operationID else { return }
                self?.append(chunk)
            }
        }
        session.onTermination = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                await Task.yield()
                await self?.finish(
                    operationID: operationID,
                    exitCode: exitCode,
                    processTimedOut: timeoutMarker.isTimedOut
                )
            }
        }
        session.onStateChange = { [weak self] event in
            guard event.operationID == operationID else { return }
            let timedOut = event.state == .stopping && event.message == "Process timed out"
            if timedOut { timeoutMarker.mark() }
            Task { @MainActor [weak self] in
                guard let self, self.activeOperationID == operationID else { return }
                if event.state == .running { self.processID = event.processID }
                if timedOut {
                    self.markTimedOut(operationID: operationID)
                    return
                }
                guard event.state == .failed else { return }
                if let message = event.message, !message.isEmpty {
                    self.errorMessage = message
                    self.append(message + "\n")
                }
                await self.finish(operationID: operationID, exitCode: event.exitCode ?? 1)
            }
        }
    }

    private func markTimedOut(operationID: String) {
        guard activeOperationID == operationID, timedOutOperationID != operationID else { return }
        timedOutOperationID = operationID
        let message = testTimeoutMessage()
        errorMessage = message
        append(message + "\n")
    }

    private func finish(
        operationID: String,
        exitCode: Int32,
        processTimedOut: Bool = false
    ) async {
        guard activeOperationID == operationID else { return }
        let timedOut = processTimedOut || timedOutOperationID == operationID
        if timedOut, errorMessage == nil {
            let message = testTimeoutMessage()
            errorMessage = message
            append(message + "\n")
        }
        // Process-backed providers report no structured results; the verdict
        // then rests on how the process ended.
        applyVerdict(
            termination: timedOut ? .timedOut : .exited(exitCode),
            scope: lastRun?.scope,
            summary: nil
        )
        activeOperationID = nil
        processID = nil
        timedOutOperationID = nil
        activeWorkspaceURL = nil
        process = nil
        extensionSession = nil
    }

    private func testTimeoutMessage() -> String {
        L10n.string("The build tool timed out.")
    }

    /// Shows Core's tool-neutral verdict. A run that executed no selected test
    /// is a failure with its own reason, never a pass on exit code 0.
    private func applyVerdict(
        termination: TestRunTermination,
        scope: LanguageTestScope?,
        summary: BuildTestResults.Summary?
    ) {
        let verdict: TestRunVerdict
        do {
            verdict = try outcomeResolver.resolveTestRunOutcome(
                termination: termination,
                scope: Self.scopeKind(scope),
                summary: summary.map {
                    TestRunSummaryCounts(
                        total: $0.total,
                        passed: $0.passed,
                        failed: $0.failed,
                        errors: $0.errors,
                        skipped: $0.skipped
                    )
                }
            )
        } catch {
            errorMessage = error.localizedDescription
            append(error.localizedDescription + "\n")
            state = .failed(exitCode: -1)
            return
        }
        switch verdict.outcome {
        case .passed: state = .passed
        case .timedOut: state = .timedOut
        case .cancelled: state = .cancelled
        case .testsFailed, .exitedWithError: state = .failed(exitCode: verdict.exitCode ?? -1)
        case .noTestsMatched, .noTestsFound:
            let message = verdict.outcome == .noTestsMatched
                ? L10n.string("No tests matched the selection.")
                : L10n.string("No tests were found.")
            errorMessage = message
            append(message + "\n")
            state = .failed(exitCode: verdict.exitCode ?? 0)
        }
    }

    private static func scopeKind(_ scope: LanguageTestScope?) -> TestRunScopeKind {
        switch scope {
        case .none, .workspace: return .workspace
        case .file: return .suite
        case .testCase(_, _, let reference?) where reference.testCase == nil: return .suite
        case .testCase: return .case
        }
    }

    private static func testTimeoutMilliseconds(for frameworkID: String?) -> Int? {
        switch frameworkID {
        case "junit": return javaTestTimeoutMilliseconds
        default: return nil
        }
    }

    private func relativeProjectPaths(_ files: [URL], workspaceURL: URL) -> [String] {
        files.compactMap { relativePath($0, workspaceURL: workspaceURL) }.sorted()
    }

    private func relativePath(_ fileURL: URL, workspaceURL: URL) -> String? {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = workspaceURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func testItem(
        from item: LanguageTestExtensionItem,
        providerID: String,
        workspaceURL: URL
    ) -> LanguageTestItem? {
        let kind: LanguageTestItemKind
        switch item.kind {
        case .workspace: kind = .workspace
        case .file: kind = .file
        case .testCase: kind = .testCase
        }
        let fileURL: URL?
        if let path = item.relativeFilePath {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
            fileURL = workspaceURL.appendingPathComponent(path).standardizedFileURL
        } else {
            fileURL = nil
        }
        return LanguageTestItem(
            id: item.id,
            providerID: providerID,
            label: item.label,
            kind: kind,
            fileURL: fileURL
        )
    }

    private func extensionScope(
        _ scope: LanguageTestScope,
        workspaceURL: URL
    ) throws -> LanguageTestExtensionScope {
        guard scope.buildReference == nil else { throw LanguageTestPlanError.unsupportedProvider("Build Provider") }
        switch scope {
        case .workspace:
            return .workspace
        case .file(let fileURL):
            guard let path = relativePath(fileURL, workspaceURL: workspaceURL) else {
                throw LanguageTestPlanError.fileOutsideWorkspace(fileURL)
            }
            return .file(relativePath: path)
        case .testCase(let identifier, let fileURL, _):
            let path: String?
            if let fileURL {
                guard let relative = relativePath(fileURL, workspaceURL: workspaceURL) else {
                    throw LanguageTestPlanError.fileOutsideWorkspace(fileURL)
                }
                path = relative
            } else {
                path = nil
            }
            return .testCase(identifier: identifier, relativeFilePath: path)
        }
    }

    private static func sharedLaunchPlan(
        from plan: LanguageRunExtensionPlan
    ) -> SharedLaunchPlan {
        let executable: SharedLaunchPlan.Executable
        switch plan.executable {
        case .toolchain(let id): executable = .toolchain(id)
        case .command(let command): executable = .command(command)
        }
        return SharedLaunchPlan(
            executable: executable,
            arguments: plan.arguments,
            workingDirectory: plan.workingDirectory,
            environment: plan.environment
        )
    }
}

@MainActor
private struct LastRun {
    let providerID: String
    let scope: LanguageTestScope
    let workspaceURL: URL
    let projectFiles: [URL]
    let options: RunOptions
}

private final class LanguageTestTimeoutMarker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
private final class RegisteredLanguageTestExtension {
    let support: LanguageSupportDeclaration
    weak var provider: (any LanguageTestExtensionProviding)?

    init(
        support: LanguageSupportDeclaration,
        provider: any LanguageTestExtensionProviding
    ) {
        self.support = support
        self.provider = provider
    }
}
