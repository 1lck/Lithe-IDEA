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
    @Published package private(set) var results: MavenTestResults?
    @Published package private(set) var output = ""
    @Published package private(set) var errorMessage: String?

    private let catalog: LanguageProviderCatalog
    private let registry: LanguageTestProviderRegistry
    private let executableResolver: any RunExecutableResolving
    private let processFactory: () -> any StreamingProcess
    private let extensionRequiredLanguageIDs: Set<String>
    private let resultParser: (@Sendable (String, URL) -> MavenTestResults?)?
    private var process: (any StreamingProcess)?
    private var extensionSession: (any LanguageExecutionSession)?
    private var languageTestExtensions: [String: RegisteredLanguageTestExtension] = [:]
    private var activeOperationID: String?
    private var timedOutOperationID: String?
    private var activeWorkspaceURL: URL?
    private var outputCapture: LanguageTestOutputCapture?
    private var lastRun: LastRun?
    private let maximumOutputCharacters = 400_000
    private static let mavenTestTimeoutMilliseconds = 120_000

    package init(
        catalog: LanguageProviderCatalog = .compatibilityFallback,
        registry: LanguageTestProviderRegistry? = nil,
        executableResolver: any RunExecutableResolving,
        processFactory: @escaping () -> any StreamingProcess,
        extensionRequiredLanguageIDs: Set<String> = [],
        resultParser: (@Sendable (String, URL) -> MavenTestResults?)? = nil
    ) {
        self.catalog = catalog
        self.registry = registry ?? .standard(catalog: catalog)
        self.executableResolver = executableResolver
        self.processFactory = processFactory
        self.extensionRequiredLanguageIDs = extensionRequiredLanguageIDs
        self.resultParser = resultParser
    }

    package var isRunning: Bool { state == .running }
    package var canRerun: Bool { lastRun != nil && !isRunning }

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
        output = ""
        results = nil
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
            let operationID = UUID().uuidString
            activeOperationID = operationID
            activeWorkspaceURL = root
            let outputCapture = LanguageTestOutputCapture(maximumCharacters: maximumOutputCharacters)
            self.outputCapture = outputCapture
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
                    outputCapture: outputCapture,
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
                    outputCapture: outputCapture,
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
            timedOutOperationID = nil
            outputCapture = nil
            activePlan = nil
            state = .failed(exitCode: -1)
            errorMessage = error.localizedDescription
            append(error.localizedDescription + "\n")
            return false
        }
    }

    package func stop() { stop(markCancelled: true) }

    package func reset() {
        stop(markCancelled: false)
        itemsByProviderID = [:]
        activePlan = nil
        activeWorkspaceURL = nil
        lastRun = nil
        results = nil
        output = ""
        errorMessage = nil
        state = .idle
    }

    package func clearOutput() {
        output = ""
        results = nil
    }

    @discardableResult
    package func rerun() -> Bool {
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
        timedOutOperationID = nil
        activeWorkspaceURL = nil
        outputCapture = nil
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
        outputCapture: LanguageTestOutputCapture,
        timeoutMarker: LanguageTestTimeoutMarker
    ) {
        process.onOutput = { [weak self, outputCapture] chunk in
            outputCapture.append(chunk)
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
            guard event.operationID == operationID,
                  event.state == .stopping,
                  event.message == "Process timed out" else { return }
            timeoutMarker.mark()
            Task { @MainActor [weak self] in
                self?.markTimedOut(operationID: operationID)
            }
        }
    }

    private func configureExtensionSession(
        _ session: any LanguageExecutionSession,
        operationID: String,
        outputCapture: LanguageTestOutputCapture,
        timeoutMarker: LanguageTestTimeoutMarker
    ) {
        session.onOutput = { [weak self, outputCapture] chunk in
            outputCapture.append(chunk)
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
        let capturedOutput = outputCapture?.snapshot() ?? output
        let parsedResults: MavenTestResults?
        let parsingWorkspaceURL = activeWorkspaceURL
        if activePlan?.frameworkID == "maven",
           let resultParser,
           let parsingWorkspaceURL {
            parsedResults = await Task.detached(priority: .utility) {
                resultParser(capturedOutput, parsingWorkspaceURL)
            }.value
        } else {
            parsedResults = nil
        }
        // Parsing may outlive stop, reset, or a replacement run. Only the
        // operation and workspace that produced the output may publish it.
        guard activeOperationID == operationID,
              activeWorkspaceURL == parsingWorkspaceURL else { return }
        results = parsedResults
        state = timedOut ? .timedOut : (exitCode == 0 ? .passed : .failed(exitCode: exitCode))
        activeOperationID = nil
        timedOutOperationID = nil
        activeWorkspaceURL = nil
        outputCapture = nil
        process = nil
        extensionSession = nil
    }

    private func testTimeoutMessage() -> String {
        let framework = activePlan?.frameworkID == "junit" ? "JUnit" : "Maven"
        return "\(framework) test run timed out after \(Self.mavenTestTimeoutMilliseconds / 1000) seconds."
    }

    private static func testTimeoutMilliseconds(for frameworkID: String?) -> Int? {
        switch frameworkID {
        case "maven", "junit": return mavenTestTimeoutMilliseconds
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
        switch scope {
        case .workspace:
            return .workspace
        case .file(let fileURL):
            guard let path = relativePath(fileURL, workspaceURL: workspaceURL) else {
                throw LanguageTestPlanError.fileOutsideWorkspace(fileURL)
            }
            return .file(relativePath: path)
        case .testCase(let identifier, let fileURL):
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

private final class LanguageTestOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumCharacters: Int
    private var value = ""

    init(maximumCharacters: Int) {
        self.maximumCharacters = maximumCharacters
    }

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        value += chunk
        if value.count > maximumCharacters {
            value.removeFirst(value.count - maximumCharacters)
        }
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
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
