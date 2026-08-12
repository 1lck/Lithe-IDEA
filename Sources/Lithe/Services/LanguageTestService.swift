import Foundation

enum LanguageTestRunState: Equatable, Sendable {
    case idle
    case running
    case passed
    case failed(exitCode: Int32)
    case cancelled
}

@MainActor
final class LanguageTestService: ObservableObject {
    @Published private(set) var itemsByProviderID: [String: [LanguageTestItem]] = [:]
    @Published private(set) var state: LanguageTestRunState = .idle
    @Published private(set) var activePlan: LanguageTestPlan?
    @Published private(set) var output = ""
    @Published private(set) var errorMessage: String?

    private let catalog: LanguageProviderCatalog
    private let registry: LanguageTestProviderRegistry
    private let executableResolver: any RunExecutableResolving
    private let processFactory: () -> any StreamingProcess
    private var process: (any StreamingProcess)?
    private var activeOperationID: String?
    private let maximumOutputCharacters = 400_000

    init(
        catalog: LanguageProviderCatalog = .standard,
        registry: LanguageTestProviderRegistry? = nil,
        executableResolver: any RunExecutableResolving,
        processFactory: @escaping () -> any StreamingProcess
    ) {
        self.catalog = catalog
        self.registry = registry ?? .standard(catalog: catalog)
        self.executableResolver = executableResolver
        self.processFactory = processFactory
    }

    convenience init(
        registry: LanguagePackRegistry,
        executableResolver: any RunExecutableResolving,
        processFactory: @escaping () -> any StreamingProcess
    ) {
        self.init(
            catalog: registry.catalog,
            registry: registry.testProviders,
            executableResolver: executableResolver,
            processFactory: processFactory
        )
    }

    var isRunning: Bool { state == .running }

    func discover(workspaceURL: URL, files: [URL]) {
        var discovered: [String: [LanguageTestItem]] = [:]
        let context = LanguageTestContext(
            workspaceURL: workspaceURL,
            projectFiles: files
        )
        for descriptor in catalog.descriptors where descriptor.capabilities.contains(.testing) {
            guard let provider = registry.provider(id: descriptor.id) else { continue }
            let items = provider.discoverTests(context: context)
            if !items.isEmpty { discovered[descriptor.id] = items }
        }
        itemsByProviderID = discovered
    }

    @discardableResult
    func run(
        providerID: String,
        scope: LanguageTestScope,
        workspaceURL: URL,
        projectFiles: [URL] = [],
        options: RunOptions = RunOptions()
    ) -> Bool {
        stop(markCancelled: false)
        output = ""
        errorMessage = nil
        let root = workspaceURL.standardizedFileURL
        do {
            guard let provider = registry.provider(id: providerID) else {
                throw LanguageTestPlanError.unsupportedProvider(providerID)
            }
            let plan = try provider.testPlan(
                scope: scope,
                context: LanguageTestContext(
                    workspaceURL: root,
                    projectFiles: projectFiles
                )
            )
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
            let process = processFactory()
            process.onOutput = { [weak self] chunk in
                Task { @MainActor [weak self] in
                    guard self?.activeOperationID == operationID else { return }
                    self?.append(chunk)
                }
            }
            process.onTermination = { [weak self] exitCode in
                Task { @MainActor [weak self] in
                    guard let self, self.activeOperationID == operationID else { return }
                    self.state = exitCode == 0 ? .passed : .failed(exitCode: exitCode)
                    self.activeOperationID = nil
                    self.process = nil
                }
            }
            self.process = process
            activeOperationID = operationID
            activePlan = plan
            state = .running
            append("$ \(resolved.executableURL.lastPathComponent) \(plan.launchPlan.arguments.joined(separator: " "))\n\n")
            try process.start(ProcessRequest(
                operationID: operationID,
                executablePath: resolved.executableURL.path,
                arguments: plan.launchPlan.arguments,
                workingDirectory: workingDirectory.path,
                environment: resolved.environment
            ))
            return true
        } catch {
            process?.stop()
            process = nil
            activeOperationID = nil
            activePlan = nil
            state = .failed(exitCode: -1)
            errorMessage = error.localizedDescription
            append(error.localizedDescription + "\n")
            return false
        }
    }

    func stop() { stop(markCancelled: true) }

    func reset() {
        stop(markCancelled: false)
        itemsByProviderID = [:]
        activePlan = nil
        output = ""
        errorMessage = nil
        state = .idle
    }

    func clearOutput() { output = "" }

    private func stop(markCancelled: Bool) {
        let wasRunning = state == .running
        activeOperationID = nil
        process?.stop()
        process = nil
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
}
