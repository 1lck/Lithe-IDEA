import Combine
import Foundation
import LitheModuleAPI
import LitheCoreContracts

// Note: 构建系统插件契约见 .agents/notes/implemented/architecture/2026-10-17-build-system-plugin-contract.md

package enum BuildModelState: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded
    case failed(String)
}

package enum BuildDependencyState: Equatable, Sendable {
    case loading
    case loaded(BuildDependencyTree)
    case failed(String)
}

package enum BuildTestDiscoveryState: Equatable, Sendable {
    case loading
    case loaded(BuildTestDiscovery)
    case failed(String)
}

package enum BuildRunState: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case failed(String)
    case cancelled
}

/// How one task or test run ended. `exitCode` is set when the tool exited.
package struct BuildRunEnd: Equatable, Sendable {
    package let runID: UUID
    package let entryID: String
    package let state: BuildRunState
    package let exitCode: Int32?

    package init(runID: UUID, entryID: String, state: BuildRunState, exitCode: Int32?) {
        self.runID = runID; self.entryID = entryID; self.state = state; self.exitCode = exitCode
    }
}

/// The execution retained by the Build output slot, including after completion.
/// Only this operation's output is exposed to callers; background model and
/// dependency loads may share the UI console without changing its history.
package struct BuildOperationSnapshot: Equatable, Sendable {
    package let id: UUID
    package let entryID: String
    package let title: String
    package var state: BuildRunState
    package var exitCode: Int32?
    package var output: String
}

/// One detected instance with what the host has loaded for it.
package struct BuildSystemEntry: Equatable, Identifiable, Sendable {
    package let instance: BuildSystemInstance
    package let declaration: DeclarativeBuildSystem
    package let source: BuildSystemPluginSource
    package var model: BuildModel?
    package var modelState: BuildModelState
    package var options: [BuildResolvedOption]
    package var sync: BuildSyncState?
    /// A file the model depends on changed after a command model was loaded.
    package var isReloadRequired: Bool
    /// By the workspace-relative project directory; the instance root for
    /// the whole instance.
    package var dependencies: [String: BuildDependencyState]

    package var id: String { instance.id }
    package var target: BuildSystemTarget {
        BuildSystemTarget(manifest: source.manifest, buildSystemID: instance.buildSystemID)
    }

    package init(
        instance: BuildSystemInstance,
        declaration: DeclarativeBuildSystem,
        source: BuildSystemPluginSource,
        model: BuildModel? = nil,
        modelState: BuildModelState = .notLoaded,
        options: [BuildResolvedOption] = [],
        sync: BuildSyncState? = nil,
        isReloadRequired: Bool = false,
        dependencies: [String: BuildDependencyState] = [:]
    ) {
        self.instance = instance; self.declaration = declaration; self.source = source
        self.model = model; self.modelState = modelState; self.options = options; self.sync = sync
        self.isReloadRequired = isReloadRequired; self.dependencies = dependencies
    }
}

/// Runs plugin build systems: detection, model loading, tasks, tests, and
/// dependency trees. Rust Core decides every command and decodes every
/// output; this service only sequences the steps and owns the processes.
///
/// One task or test run owns the output at a time. Model and dependency
/// commands run beside it and append their output under a header, so a long
/// first sync still shows its progress.
@MainActor
package final class BuildSystemService: ObservableObject {
    package static let modelTimeout: Duration = .seconds(15 * 60)
    private static let visibleOutputLimit = 1_000_000
    /// Rust Core refuses larger output.
    private static let decodedOutputLimit = 32 * 1024 * 1024

    @Published package private(set) var entries: [BuildSystemEntry] = []
    @Published package private(set) var isDetecting = false
    /// Manifests Core refused and build systems another plugin answers for.
    @Published package private(set) var issues: [String] = []
    @Published package private(set) var runState: BuildRunState = .idle {
        didSet { refreshActivity() }
    }
    /// True while a task, test, model, or dependency command runs.
    @Published package private(set) var hasActiveWork = false
    @Published package private(set) var runningTitle: String?
    @Published package private(set) var output = ""
    /// Directories of every command that wrote the current output, so relative
    /// source paths are resolved against the instance roots that produced them.
    @Published package private(set) var outputRoots: [URL] = []
    @Published package private(set) var diagnostics: [BuildDiagnostic] = []
    @Published package private(set) var testResults: BuildTestResults?
    @Published package private(set) var operation: BuildOperationSnapshot?
    @Published private var testDiscoveries: [String: BuildTestDiscoveryState] = [:]
    private var discoverySnapshots: [String: DiscoverySnapshot] = [:]
    private struct DiscoverySnapshot: Equatable {
        let source: BuildSystemPluginSource
        let fingerprint: String?
        let settings: [String: ToolingJSONValue]
        let revision: Int
    }
    package private(set) var workspaceURL: URL?
    /// Nil while detection is pending. An empty value means no plugin import.
    @Published package private(set) var languageImport: JavaLanguageImportConfiguration?
    package var onLanguageImportChanged: ((URL) -> Void)?
    private var languageImportFailure: String?
    private var detectionID: UUID?
    private var importWaiters: [UUID: CheckedContinuation<JavaLanguageImportConfiguration, Error>] = [:]
    private var importTimeouts: [UUID: Task<Void, Never>] = [:]

    private let planner: any BuildSystemPlanning
    private let tools: any BuildToolResolving
    private let optionsStore: any BuildOptionsStoring
    private let stateLocator: any BuildSystemStateLocating
    private let runner: any BuildCommandRunning
    private let providers: (any BuildProviderRequesting)?
    private let runLauncher: (any BuildRunLaunching)?
    private var preparingDebugID: UUID?
    private var preparedApplication: (source: BuildSystemPluginSource, operationID: String)?
    private let settings: @MainActor (String) -> [String: ToolingJSONValue]
    private let waitForRedetection: @Sendable () async throws -> Void
    private let sources: @MainActor () -> [BuildSystemPluginSource]

    /// Bumped whenever the workspace changes, so late results are dropped.
    private var generation = 0
    /// Bumped whenever a load changes one entry's model or dependencies.
    /// Detection captures these numbers with its snapshot and does not
    /// overwrite state that changed while it ran. Model and dependency
    /// revisions are separate: a dependency result must not replace a model
    /// the detection just read.
    private var modelRevisions: [String: Int] = [:]
    /// A producer's options/package may change and change back while it loads.
    /// Other producers' ordinary publications only revoke consumer snapshots.
    private var modelConfigurationRevisions: [String: UInt64] = [:]
    private var dependencyRevisions: [String: Int] = [:]
    /// Bumped when a watched workspace file changes, so a load that started
    /// before the change can tell its result is based on older files.
    private var fileRevision = 0
    private var providerConfigurationRevision = 0
    private var nativeOptionsRevisions: [String: Int] = [:]
    private var nativeConfiguration: BuildNativeConfigurationCoordinator?
    private var nativeObservation: AnyCancellable?
    private var modelInputRevision: UInt64 = 0
    private var providerRunID: UUID?
    private var preparingApplicationID: UUID?
    private var detectionTask: Task<Void, Never>?
    private var redetectTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var runID: UUID?
    private var runEntryID: String?
    /// Identity and cancellation travel together so a replaced load cannot
    /// release its successor's slot or publish a late result.
    private struct LoadTask {
        let id: UUID
        let task: Task<Void, Never>

        func cancel() { task.cancel() }
    }

    /// Identity of one run, so a decode that finishes after the run was
    /// stopped or replaced cannot publish its results.
    private struct RunIdentity: Sendable {
        let id: UUID
        let generation: Int
    }

    /// Who may append a command's streamed output: the workspace generation
    /// plus the run or load task that started it.
    private enum CommandOwner: Sendable {
        case run(RunIdentity)
        case modelLoad(generation: Int, entryID: String, id: UUID)
        case dependencyLoad(generation: Int, taskKey: String, id: UUID)
    }

    private var modelTasks: [String: LoadTask] = [:] {
        didSet { refreshActivity() }
    }
    private var dependencyTasks: [String: LoadTask] = [:] {
        didSet { refreshActivity() }
    }
    private var outputByteCount = 0

    package init(
        planner: any BuildSystemPlanning,
        tools: any BuildToolResolving,
        optionsStore: any BuildOptionsStoring,
        stateLocator: any BuildSystemStateLocating,
        runner: any BuildCommandRunning,
        providers: (any BuildProviderRequesting)? = nil,
        runLauncher: (any BuildRunLaunching)? = nil,
        nativeConfigurationFiles: (any BuildNativeConfigurationStoring)? = nil,
        settings: @escaping @MainActor (String) -> [String: ToolingJSONValue] = { _ in [:] },
        waitForRedetection: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(500))
        },
        sources: @escaping @MainActor () -> [BuildSystemPluginSource]
    ) {
        self.planner = planner
        self.tools = tools
        self.optionsStore = optionsStore
        self.stateLocator = stateLocator
        self.runner = runner
        self.providers = providers
        self.runLauncher = runLauncher
        self.settings = settings
        self.waitForRedetection = waitForRedetection
        self.sources = sources
        let configuration = BuildNativeConfigurationCoordinator(
            planner: planner, tools: tools, providers: providers, files: nativeConfigurationFiles,
            context: { [weak self] id in try self?.nativeConfigurationContext(id) },
            didSave: { [weak self] id in self?.nativeConfigurationDidSave(id) }
        )
        nativeConfiguration = configuration
        configuration.onActivityChanged = { [weak self] in self?.refreshActivity() }
        nativeObservation = configuration.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Every run that ends, stopped or superseded runs included, so a caller
    /// that started one can tell how its own run ended.
    package let runEnded = PassthroughSubject<BuildRunEnd, Never>()
    package let applicationLaunched = PassthroughSubject<String, Never>()

    /// The task, test, or application preparation (including save) in progress.
    package var currentRunID: UUID? { runID }
    package var isRunning: Bool { runState == .running }
    package var isLoadingModel: Bool { !modelTasks.isEmpty }
    package var isLoadingDependencies: Bool { !dependencyTasks.isEmpty }
    /// True when an enabled plugin declares a build system, detected or not.
    package var hasBuildSystemPlugins: Bool { !sources().isEmpty }

    package func entry(_ id: String) -> BuildSystemEntry? {
        entries.first { $0.id == id }
    }

    package func nativeConfigurationState(_ entryID: String) -> BuildNativeConfigurationState {
        nativeConfiguration?.state(entryID) ?? BuildNativeConfigurationState()
    }

    @discardableResult
    package func readNativeConfiguration(_ entryID: String, allowProjectTool: Bool = false) async throws -> BuildNativeConfiguration {
        guard let nativeConfiguration else { throw BuildSystemServiceError(L10n.string("Native configuration is unavailable.")) }
        return try await nativeConfiguration.read(entryID, allowProjectTool: allowProjectTool)
    }

    @discardableResult
    package func saveNativeConfiguration(_ entryID: String, snapshot: BuildNativeConfiguration,
                                         edits: BuildNativeConfigurationEdits) async throws -> BuildNativeConfiguration {
        guard let nativeConfiguration else { throw BuildSystemServiceError(L10n.string("Native configuration is unavailable.")) }
        return try await nativeConfiguration.save(entryID, snapshot: snapshot, edits: edits)
    }

    private func nativeConfigurationContext(_ entryID: String) throws -> BuildNativeConfigurationContext? {
        guard let workspaceURL, let entry = entry(entryID), entry.declaration.nativeConfiguration,
              sources().contains(entry.source) else { return nil }
        return BuildNativeConfigurationContext(entryID: entryID, source: entry.source,
            buildSystemID: entry.instance.buildSystemID, workspace: workspaceURL, generation: generation,
            configurationRevision: providerConfigurationRevision,
            optionsRevision: nativeOptionsRevisions[entry.instance.buildSystemID, default: 0],
            settings: settings(entry.source.pluginID), plan: try planContext(entry, workspaceURL: workspaceURL))
    }

    private func nativeConfigurationDidSave(_ entryID: String) {
        guard let entry = entry(entryID), let workspaceURL else { return }
        let buildSystemID = entry.instance.buildSystemID
        providerConfigurationRevision += 1
        invalidateTestDiscovery(buildSystemID: buildSystemID)
        if providerRunID != nil { stopRun() }
        for affected in entries where affected.instance.buildSystemID == buildSystemID {
            modelTasks.removeValue(forKey: affected.id)?.cancel()
            for key in Array(dependencyTasks.keys) where Self.entryID(ofDependencyTask: key) == affected.id {
                dependencyTasks.removeValue(forKey: key)?.cancel()
            }
            update(affected.id) {
                $0.isReloadRequired = true
                if $0.modelState == .loading { $0.modelState = $0.model == nil ? .notLoaded : .loaded }
                $0.dependencies = [:]
            }
            modelRevisions[affected.id, default: 0] += 1
            dependencyRevisions[affected.id, default: 0] += 1
        }
        invalidateProducerConfiguration(buildSystemID: buildSystemID)
        // The selected path can stay the same while its native content changes.
        // Language import must re-read that source before its next project sync.
        onLanguageImportChanged?(workspaceURL)
    }

    // MARK: Workspace

    /// Forgets the previous workspace and detects the new one.
    package func reset(workspaceURL: URL?) {
        stop()
        generation += 1
        modelInputRevision += 1
        detectionTask?.cancel(); detectionTask = nil
        redetectTask?.cancel(); redetectTask = nil
        self.workspaceURL = workspaceURL?.standardizedFileURL
        entries = []
        modelRevisions = [:]
        modelConfigurationRevisions = [:]
        nativeOptionsRevisions = [:]
        dependencyRevisions = [:]
        fileRevision = 0
        issues = []
        isDetecting = false
        runState = .idle
        runningTitle = nil
        clearOutput()
        operation = nil
        detect()
    }

    /// Detects the instances again. Static and host-integration models are
    /// read again with them; a loaded command model is kept and marked
    /// stale when the files it depends on changed.
    package func detect() {
        guard let workspaceURL else { return }
        redetectTask?.cancel(); redetectTask = nil
        detectionTask?.cancel()
        let detectionID = UUID()
        self.detectionID = detectionID
        languageImport = nil
        languageImportFailure = nil
        let sources = sources()
        guard !sources.isEmpty else {
            entries = []
            issues = []
            isDetecting = false
            publishLanguageImport(JavaLanguageImportConfiguration(), workspaceURL: workspaceURL)
            return
        }
        isDetecting = true
        let storedOptions: [String: [String: ToolingJSONValue]]
        let emptyMultiSelectOptions: [String: [String: Set<String>]]
        let instanceOptions: [String: [String: [String: ToolingJSONValue]]]
        let instanceDefaults: [String: [String: ToolingJSONValue]]
        do {
            storedOptions = Dictionary(
                try sources.flatMap(\.buildSystems).map {
                    ($0.id, try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: $0.id))
                },
                uniquingKeysWith: { first, _ in first }
            )
            emptyMultiSelectOptions = Dictionary(
                try sources.flatMap(\.buildSystems).map {
                    ($0.id, try optionsStore.emptyMultiSelectOptions(workspaceURL: workspaceURL, buildSystemID: $0.id))
                },
                uniquingKeysWith: { first, _ in first }
            )
            instanceOptions = Dictionary(
                try sources.flatMap(\.buildSystems).map {
                    ($0.id, try optionsStore.instanceOptions(workspaceURL: workspaceURL, buildSystemID: $0.id))
                },
                uniquingKeysWith: { first, _ in first }
            )
            instanceDefaults = Dictionary(
                try sources.flatMap(\.buildSystems).map {
                    ($0.id, try optionsStore.instanceDefaults(workspaceURL: workspaceURL, buildSystemID: $0.id))
                }, uniquingKeysWith: { first, _ in first }
            )
        } catch {
            entries = []
            isDetecting = false
            failLanguageImport(error)
            return
        }
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let modelRevisions = modelRevisions
        let dependencyRevisions = dependencyRevisions
        let planner = planner
        let generation = generation
        detectionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try Self.detectEntries(
                        planner: planner,
                        workspaceURL: workspaceURL,
                        sources: sources,
                        storedOptions: storedOptions,
                        instanceOptions: instanceOptions,
                        instanceDefaults: instanceDefaults,
                        emptyMultiSelectOptions: emptyMultiSelectOptions,
                        previous: previous
                    )
                }
            }.value
            guard let self, self.generation == generation,
                  self.detectionID == detectionID, !Task.isCancelled else { return }
            self.isDetecting = false
            switch result {
            case .success(let detected):
                do {
                    if try self.migrateInstanceOptions(entries: detected.entries, workspaceURL: workspaceURL) {
                        self.detect()
                        return
                    }
                } catch {
                    self.entries = []
                    self.issues = []
                    self.failLanguageImport(error)
                    return
                }
                let current = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.id, $0) })
                let publishedBefore = self.entries.filter { $0.declaration.sharesModel }
                self.entries = detected.entries.map { detectedEntry in
                    guard let currentEntry = current[detectedEntry.id],
                          currentEntry.instance.pluginID == detectedEntry.instance.pluginID
                    else { return detectedEntry }
                    let modelChanged = (self.modelRevisions[detectedEntry.id] ?? 0)
                        != (modelRevisions[detectedEntry.id] ?? 0)
                    let dependenciesChanged = (self.dependencyRevisions[detectedEntry.id] ?? 0)
                        != (dependencyRevisions[detectedEntry.id] ?? 0)
                    var merged = detectedEntry
                    if modelChanged {
                        // A model load finished while detection ran; its model
                        // and everything derived from it are newer.
                        merged.model = currentEntry.model
                        merged.modelState = currentEntry.modelState
                        merged.options = currentEntry.options
                        merged.sync = currentEntry.sync
                        merged.isReloadRequired = currentEntry.isReloadRequired
                        merged.dependencies = currentEntry.dependencies
                    } else if dependenciesChanged {
                        // Only the dependency tree changed; keep the model
                        // detection just read.
                        merged.dependencies = currentEntry.dependencies
                    }
                    if !merged.declaration.modelInputs.isEmpty, currentEntry.isReloadRequired { merged.isReloadRequired = true }
                    return merged
                }
                if publishedBefore != self.entries.filter({ $0.declaration.sharesModel }) { self.invalidateModelInputs() }
                self.issues = detected.issues
                let inputs: [LanguageImportInput]
                do {
                    try self.persistDroppedOptions()
                    try self.restoreSavedChoices(workspaceURL: workspaceURL)
                    inputs = try self.entries.map { entry in
                        LanguageImportInput(
                            entry: entry,
                            options: try self.storedOptions(for: entry, workspaceURL: workspaceURL)
                        )
                    }
                } catch {
                    self.entries = []
                    self.failLanguageImport(error)
                    return
                }
                // Discovery is passive: importing a project cannot execute a
                // wrapper or probe the build tool before user confirmation.
                let normalized = await Task.detached(priority: .userInitiated) {
                    Result { try Self.languageImports(planner: planner, workspaceURL: workspaceURL, inputs: inputs) }
                }.value
                guard self.generation == generation, self.detectionID == detectionID,
                      !Task.isCancelled else { return }
                switch normalized {
                case .success(let imports):
                    var executables: [String: URL] = [:]
                    for input in inputs {
                        guard case .maven? = imports[input.entry.id],
                              let invocation = try? planner.invocationPlan(
                                input.entry.target, root: input.entry.instance.root,
                                settings: self.settings(input.entry.source.pluginID)
                              )
                        else { continue }
                        executables[input.entry.id] = self.tools.languageImportExecutable(invocation, workspaceURL: workspaceURL)
                    }
                    let withExecutables = executables
                    let configured = await Task.detached(priority: .userInitiated) {
                        Result {
                            try Self.languageImports(
                                planner: planner, workspaceURL: workspaceURL, inputs: inputs,
                                executables: withExecutables, initial: imports
                            )
                        }
                    }.value
                    guard self.generation == generation, self.detectionID == detectionID,
                          !Task.isCancelled else { return }
                    switch configured {
                    case .success(let values):
                        self.publishLanguageImport(Self.workspaceImport(inputs: inputs, imports: values), workspaceURL: workspaceURL)
                    case .failure(let error): self.failLanguageImport(error)
                    }
                case .failure(let error): self.failLanguageImport(error)
                }
            case .failure(let error):
                self.entries = []
                self.issues = [error.localizedDescription]
                self.failLanguageImport(error)
            }
        }
    }

    /// Ends what a now disabled plugin started and detects again with the
    /// plugins enabled now, so its instances leave the tool window.
    package func pluginsChanged() {
        nativeConfiguration?.invalidate()
        providerConfigurationRevision += 1
        for producer in entries where producer.declaration.sharesModel {
            modelConfigurationRevisions[producer.id, default: 0] += 1
        }
        invalidateModelInputs()
        if preparingApplicationID != nil { stopRun() }
        if let runEntryID, testDiscoveries[runEntryID] == .loading { stopRun() }
        testDiscoveries = [:]
        discoverySnapshots = [:]
        let enabled = Set(sources().map(\.pluginID))
        let removed = Set(entries.filter { !enabled.contains($0.instance.pluginID) }.map(\.id))
        if let runEntryID, removed.contains(runEntryID) { stopRun() }
        if let preparedApplication, !sources().contains(preparedApplication.source) { stopPreparedApplication() }
        for key in Array(modelTasks.keys) where removed.contains(key) {
            modelTasks.removeValue(forKey: key)?.cancel()
        }
        for key in Array(dependencyTasks.keys) where removed.contains(Self.entryID(ofDependencyTask: key)) {
            dependencyTasks.removeValue(forKey: key)?.cancel()
        }
        // A disabled plugin's provider stops. Package replacement and
        // uninstall stop theirs earlier, through the plugin manager.
        let packages = Set(sources().map { [$0.pluginID, $0.packageURL.standardizedFileURL.path] })
        providers?.retainProviders { packages.contains([$0.pluginID, $0.packageURL.path]) }
        detect()
    }

    /// Detects again shortly after a file the models depend on changed.
    /// Several saves in a row cost one detection.
    package func workspaceFilesChanged(_ urls: [URL]) {
        guard let workspaceURL, !entries.isEmpty else { return }
        // A load can read a subproject file before the model lists it, so any
        // reported change invalidates a model load that is in flight.
        fileRevision += 1
        if preparingApplicationID != nil { stopRun() }
        let root = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        let changed = Set(urls.compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            if path == workspaceURL.path { return "." }
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
        })
        // Source edits change discovery even when no build configuration did.
        if !changed.isEmpty {
            if let runEntryID, testDiscoveries[runEntryID] == .loading { stopRun() }
            testDiscoveries = [:]
            discoverySnapshots = [:]
        }
        let preferencesChanged = changed.contains(".lithe/build/options.json")
        if preferencesChanged {
            nativeConfiguration?.invalidate()
            for id in Set(entries.map(\.instance.buildSystemID)) {
                nativeOptionsRevisions[id, default: 0] += 1
            }
        }
        let affected = preferencesChanged || entries.contains { entry in
            entry.sync?.watch.contains(where: changed.contains) == true
        }
        guard affected else { return }
        for entry in entries where entry.declaration.sharesModel && (preferencesChanged || entry.sync?.watch.contains(where: changed.contains) == true) {
            update(entry.id) { $0.isReloadRequired = true }
        }
        invalidateModelInputs()
        providerConfigurationRevision += 1
        if providerRunID != nil { stopRun() }
        // Reject the old input immediately; consumers wait for the coalesced
        // detection instead of starting Java with pre-save import settings.
        detectionTask?.cancel(); detectionTask = nil
        detectionID = nil
        languageImport = nil
        languageImportFailure = nil
        isDetecting = false
        redetectTask?.cancel()
        let waitForRedetection = waitForRedetection
        redetectTask = Task { [weak self] in
            do { try await waitForRedetection() } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.redetectTask = nil
            self.detect()
        }
    }

    // MARK: Language import

    /// Waits for the current detection, including option normalization. A
    /// cancelled waiter never cancels detection shared by other consumers.
    package func prepareLanguageImport(workspaceURL: URL) async throws -> JavaLanguageImportConfiguration {
        guard self.workspaceURL == workspaceURL.standardizedFileURL else { throw CancellationError() }
        if let languageImport { return languageImport }
        if let languageImportFailure { throw BuildSystemServiceError(languageImportFailure) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                importWaiters[id] = continuation
                importTimeouts[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    self?.finishImportWaiter(id, result: .failure(BuildSystemServiceError(
                        L10n.string("Build-system language import preparation timed out. Retry project loading.")
                    )))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishImportWaiter(id, result: .failure(CancellationError()))
            }
        }
    }

    private func publishLanguageImport(_ value: JavaLanguageImportConfiguration, workspaceURL: URL) {
        languageImport = value
        languageImportFailure = nil
        finishImportWaiters(.success(value))
        onLanguageImportChanged?(workspaceURL)
    }

    private func failLanguageImport(_ error: Error) {
        languageImportFailure = error.localizedDescription
        issues.append(error.localizedDescription)
        finishImportWaiters(.failure(error))
    }

    private func finishImportWaiter(_ id: UUID, result: Result<JavaLanguageImportConfiguration, Error>) {
        importTimeouts.removeValue(forKey: id)?.cancel()
        importWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishImportWaiters(_ result: Result<JavaLanguageImportConfiguration, Error>) {
        for id in Array(importWaiters.keys) { finishImportWaiter(id, result: result) }
    }

    private struct LanguageImportInput: Sendable {
        let entry: BuildSystemEntry
        let options: [String: ToolingJSONValue]
    }

    nonisolated private static func languageImports(
        planner: any BuildSystemPlanning, workspaceURL: URL, inputs: [LanguageImportInput],
        executables: [String: URL] = [:], initial: [String: BuildLanguageImport]? = nil
    ) throws -> [String: BuildLanguageImport] {
        var imports = initial ?? [:]
        for input in inputs {
            try Task.checkCancellation()
            if initial != nil && executables[input.entry.id] == nil { continue }
            let resolution = try planner.resolveOptions(
                input.entry.target, options: input.options, modelValues: input.entry.model?.optionValues
            )
            imports[input.entry.id] = try planner.languageImport(
                input.entry.target, workspaceURL: workspaceURL, root: input.entry.instance.root,
                options: effectiveOptionValues(resolution, stored: input.options),
                executableURL: executables[input.entry.id]
            )
        }
        return imports
    }

    /// JDT accepts one context of each kind. Prefer the workspace root, then
    /// the shallowest instance, with stable path/ID ordering for ties. Never
    /// combine Profiles or machine paths from unrelated reactors.
    nonisolated private static func workspaceImport(
        inputs: [LanguageImportInput], imports: [String: BuildLanguageImport]
    ) -> JavaLanguageImportConfiguration {
        let ordered = inputs.sorted {
            let left = $0.entry.instance, right = $1.entry.instance
            let leftDepth = left.root == "." ? 0 : left.root.split(separator: "/").count
            let rightDepth = right.root == "." ? 0 : right.root.split(separator: "/").count
            return (leftDepth, left.root, left.id, left.pluginID) < (rightDepth, right.root, right.id, right.pluginID)
        }
        var maven: MavenLaunchContext?
        var gradle: JavaGradleImportConfiguration?
        for input in ordered {
            switch imports[input.entry.id] {
            case .maven(let context)?: if maven == nil { maven = context }
            case .gradle(let context)?: if gradle == nil { gradle = context }
            case nil: break
            }
        }
        return JavaLanguageImportConfiguration(mavenContext: maven, javaGradle: gradle)
    }

    // MARK: Model

    /// Runs the model command of a command-sourced instance. Other sources
    /// are read again by detection. `reason` tells a provider whether it
    /// may answer from its own snapshot.
    package func loadModel(_ entryID: String, reason: BuildLoadReason = .initial) {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        if preparingApplicationID != nil, runEntryID == entryID { stopRun() }
        switch entry.instance.modelSource {
        case .static?, .hostIntegration?:
            detect()
            return
        case nil:
            return
        case .command?, .provider?:
            break
        }
        modelTasks[entryID]?.cancel()
        update(entryID) {
            $0.modelState = .loading
            if entry.declaration.sharesModel { $0.isReloadRequired = $0.model != nil }
        }
        noteModelChanged(entryID)
        let publicationRevision = entry.declaration.sharesModel ? modelConfigurationRevisions[entryID, default: 0] : nil
        let generation = generation
        let id = UUID()
        // The model command depends on the options; a change while it runs
        // makes the result stale even though it still publishes.
        let optionFingerprint = optionFingerprint(entry, workspaceURL: workspaceURL)
        let startFileRevision = fileRevision
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performModelLoad(
                entry,
                workspaceURL: workspaceURL,
                reason: reason,
                owner: .modelLoad(generation: generation, entryID: entryID, id: id)
            )
            guard self.generation == generation, self.modelTasks[entryID]?.id == id,
                  !Task.isCancelled else { return }
            self.modelTasks[entryID] = nil
            switch result {
            case .success(let loaded):
                let configChanged: Bool = {
                    // An exporter cannot make an ABA-configured in-flight model public.
                    if let publicationRevision, self.modelConfigurationRevisions[entryID, default: 0] != publicationRevision { return true }
                    guard self.fileRevision == startFileRevision else { return true }
                    guard let current = self.entry(entryID),
                          let currentFingerprint = self.optionFingerprint(current, workspaceURL: workspaceURL)
                    else { return false }
                    return currentFingerprint != optionFingerprint
                }()
                self.update(entryID) {
                    $0.model = loaded.model
                    $0.modelState = .loaded
                    $0.options = loaded.options ?? $0.options
                    $0.sync = loaded.sync ?? $0.sync
                    $0.isReloadRequired = configChanged
                    $0.dependencies = [:]
                }
                self.noteModelChanged(entryID)
                do { try self.refreshOptions(buildSystemID: entry.instance.buildSystemID) }
                catch {
                    self.entries = []
                    self.failLanguageImport(error)
                    return
                }
                // Model-provided choices may remove an import option even
                // when the user has not changed it. Discard any old snapshot.
                self.detect()
            case .failure(let error) where error is CancellationError:
                self.update(entryID) {
                    $0.modelState = $0.model == nil ? .notLoaded : .loaded
                }
                self.noteModelChanged(entryID)
            case .failure(let error):
                self.update(entryID) { $0.modelState = .failed(error.localizedDescription) }
                self.noteModelChanged(entryID)
            }
        }
        modelTasks[entryID] = LoadTask(id: id, task: task)
    }

    private struct LoadedModel: Sendable {
        let model: BuildModel
        let options: [BuildResolvedOption]?
        let sync: BuildSyncState?
    }

    private func performModelLoad(
        _ entry: BuildSystemEntry,
        workspaceURL: URL,
        reason: BuildLoadReason,
        owner: CommandOwner
    ) async -> Result<LoadedModel, Error> {
        do {
            let context = try planContext(entry, workspaceURL: workspaceURL)
            let outputFile = try context.workspaceStateDirectory.map { try stateLocator.allocateOutputFile(in: $0) }
            defer { if let outputFile { stateLocator.removeOutputFile(outputFile) } }
            let planner = planner
            let plan = try await outputPlan(entry, workspaceURL: workspaceURL, reason: reason, owner: owner) { hints in
                try planner.modelPlan(entry.target, context: context, outputFile: outputFile, providerHints: hints)
            }
            let title = L10n.string("Loading \(entry.instance.displayName) model")
            let output = try await captureOutput(
                plan,
                entry: entry,
                workspaceURL: workspaceURL,
                outputFile: outputFile,
                title: title,
                timeout: Self.modelTimeout,
                owner: owner
            )
            let target = entry.target
            let root = entry.instance.root
            let loaded = try await Task.detached(priority: .userInitiated) {
                let model = try planner.decodeModel(
                    target, workspaceURL: workspaceURL, root: root, output: output, options: context.options
                )
                return LoadedModel(
                    model: model,
                    options: try? planner.resolveOptions(
                        target, options: context.options, modelValues: model.optionValues
                    ).options,
                    sync: try? planner.syncFingerprint(
                        target, workspaceURL: workspaceURL, root: root,
                        projects: model.projects.map(\.path), options: context.options
                    )
                )
            }.value
            guard modelInputsAreCurrent(context.modelInputs) else { throw CancellationError() }
            return .success(loaded)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Tasks and tests

    /// Saved references resolve against the currently enabled plugin and model.
    @discardableResult
    package func runProviderConfiguration(_ configuration: RunConfiguration, workspace: URL) -> UUID? {
        guard workspace.standardizedFileURL == workspaceURL, let reference = configuration.buildProvider,
              let entry = entries.first(where: { $0.instance.pluginID == reference.pluginID
                && $0.instance.buildSystemID == reference.buildSystemID && $0.instance.root == reference.root }) else { return nil }
        return runApplication(entry.id, request: reference.request, title: configuration.name, configuration: configuration)
    }

    package func cancelRun(_ id: UUID) { if runID == id { stopRun() } }

    package func cancelDebugPreparation() { if let id = preparingDebugID { cancelRun(id) } }

    /// Debug owns the launched session; this service owns only preparation.
    @discardableResult
    package func debugApplication(_ entryID: String, request: BuildRunRequest, title: String,
                                  launch: @escaping @MainActor (BuildSystemPluginSource, BuildDebugPreparation) throws -> Void) -> UUID? {
        prepareApplication(entryID, request: request, title: title, debugLaunch: launch)
    }

    @discardableResult
    package func debugProviderConfiguration(_ configuration: RunConfiguration, workspace: URL,
                                  launch: @escaping @MainActor (BuildSystemPluginSource, BuildDebugPreparation) throws -> Void) -> UUID? {
        guard workspace.standardizedFileURL == workspaceURL, let reference = configuration.buildProvider,
              let entry = entries.first(where: { $0.instance.pluginID == reference.pluginID
                && $0.instance.buildSystemID == reference.buildSystemID && $0.instance.root == reference.root }) else { return nil }
        return debugApplication(entry.id, request: reference.request, title: configuration.name, launch: launch)
    }

    /// The provider owns build/launch facts; the Run host owns the application.
    @discardableResult
    package func runApplication(_ entryID: String, request: BuildRunRequest, title: String, configuration: RunConfiguration? = nil,
                                beforePreparing: @escaping @MainActor () async -> Bool = { true }) -> UUID? {
        prepareApplication(entryID, request: request, title: title, configuration: configuration, beforePreparing: beforePreparing)
    }

    private func prepareApplication(_ entryID: String, request: BuildRunRequest, title: String,
                                    configuration: RunConfiguration? = nil,
                                    beforePreparing: @escaping @MainActor () async -> Bool = { true },
                                    debugLaunch: (@MainActor (BuildSystemPluginSource, BuildDebugPreparation) throws -> Void)? = nil) -> UUID? {
        guard let workspaceURL, let entry = entry(entryID), let model = entry.model,
              !entry.isReloadRequired, entry.modelState == .loaded,
              let project = model.projects.first(where: { $0.id == request.projectID }),
              let target = model.targets.first(where: { $0.id == request.targetID && $0.projectID == project.id }),
              entry.declaration.providerRuns.contains(where: { $0.id == request.run && (debugLaunch == nil || $0.debugAdapter != nil) }) else { return nil }
        let origin = configuration ?? RunConfiguration(id: "build:" + entryID + ":" + request.run + ":" + request.targetID,
            name: title, kind: .process(provider: "build.provider"), execution: .application, modulePath: nil, mainClass: nil,
            buildProvider: BuildProviderRunReference(pluginID: entry.instance.pluginID, buildSystemID: entry.instance.buildSystemID,
                root: entry.instance.root, run: request.run, projectID: request.projectID, targetID: request.targetID,
                userArguments: request.userArguments))
        if debugLaunch == nil { stopPreparedApplication() }
        let sourceRevision = fileRevision
        return startRun(entryID, title: title) { service, run in
            // Own the save/readiness stage in the same slot as preparation.
            // An ignored cancellation must not startRun again and replace newer work.
            service.providerRunID = run.id
            service.preparingApplicationID = run.id
            defer { if service.preparingApplicationID == run.id { service.preparingApplicationID = nil } }
            defer { if service.providerRunID == run.id { service.providerRunID = nil } }
            guard await beforePreparing(), service.isCurrent(run),
                  service.fileRevision == sourceRevision,
                  let current = service.entry(entryID), current.source == entry.source,
                  current.model == model, current.modelState == .loaded, !current.isReloadRequired
            else { throw CancellationError() }
            guard let providers = service.providers, debugLaunch != nil || service.runLauncher != nil else {
                throw BuildSystemServiceError(Self.providerUnsupportedMessage)
            }
            let context = try service.planContext(entry, workspaceURL: workspaceURL)
            let planned: BuildProviderRequest
            if debugLaunch != nil {
                planned = try service.planner.prepareDebugPlan(entry.target, context: context, run: request.run,
                    project: BuildSelection(project: project), selectedTarget: BuildSelection(target: target), userArguments: request.userArguments)
            } else {
                planned = try service.planner.prepareRunPlan(entry.target, context: context, run: request.run,
                    project: BuildSelection(project: project), selectedTarget: BuildSelection(target: target), userArguments: request.userArguments)
            }
            let validConfiguration = service.runValidity(.provider(planned), entry: entry, workspaceURL: workspaceURL, run: run)
            let isValid: @MainActor @Sendable () -> Bool = { [weak service] in
                guard let service else { return false }
                return validConfiguration() && service.fileRevision == sourceRevision
                    && service.entry(entryID)?.model == model && service.entry(entryID)?.modelState == .loaded
                    && service.entry(entryID)?.isReloadRequired == false
            }
            if debugLaunch != nil { service.preparingDebugID = run.id }
            defer { if service.preparingDebugID == run.id { service.preparingDebugID = nil } }
            let resolved = try await service.providerRequestWithTool(planned, entry: entry, workspaceURL: workspaceURL, run: run)
            guard isValid() else { throw CancellationError() }
            let progress: @MainActor @Sendable (BuildProviderProgress) -> Void = { [weak service] progress in
                guard let service, isValid() else { return }
                if let output = progress.output { service.appendOutput(output, in: service.outputDirectory(entry), owner: .run(run)) }
                else if let message = progress.message { service.appendOutput(message + "\n", in: service.outputDirectory(entry), owner: .run(run)) }
            }
            let providerTarget = Self.providerTarget(entry, workspaceURL: workspaceURL)
            let result: ToolingJSONValue
            if debugLaunch != nil {
                result = try await providers.prepareDebug(resolved, on: providerTarget, timeout: .seconds(3600), progress: progress)
            } else {
                result = try await providers.prepareRun(resolved, on: providerTarget, timeout: .seconds(3600), progress: progress)
            }
            guard isValid() else { throw CancellationError() }
            let planner = service.planner
            if let debugLaunch {
                let preparation = try await Task.detached(priority: .userInitiated) {
                    try planner.decodeDebugPreparation(entry.target, workspaceURL: workspaceURL, root: context.root,
                                                       run: request.run, result: result)
                }.value
                guard isValid() else { throw CancellationError() }
                try debugLaunch(entry.source, preparation)
                return 0
            }
            let preparation = try await Task.detached(priority: .userInitiated) {
                try planner.decodeRunPreparation(entry.target, workspaceURL: workspaceURL, root: context.root, result: result)
            }.value
            guard isValid() else { throw CancellationError() }
            guard let launcher = service.runLauncher else { throw BuildSystemServiceError(Self.providerUnsupportedMessage) }
            let operationID = try launcher.launchPreparedRun(preparation, workspaceURL: workspaceURL, title: title, configuration: origin)
            service.preparedApplication = (entry.source, operationID)
            service.applicationLaunched.send(entryID)
            return 0
        }
    }

    private func stopPreparedApplication() {
        if let preparedApplication { runLauncher?.stopPreparedRun(preparedApplication.operationID) }
        preparedApplication = nil
    }

    /// Discovery is user-triggered and independent of a plugin page. Cached
    /// selectors are visible/runnable only for their exact configuration.
    package func testDiscovery(_ entryID: String) -> BuildTestDiscoveryState? {
        guard let workspaceURL, let entry = entry(entryID),
              discoverySnapshots[entryID] == discoverySnapshot(entry, workspaceURL: workspaceURL)
        else { return nil }
        return testDiscoveries[entryID]
    }

    private func discoverySnapshot(_ entry: BuildSystemEntry, workspaceURL: URL) -> DiscoverySnapshot {
        DiscoverySnapshot(source: entry.source, fingerprint: optionFingerprint(entry, workspaceURL: workspaceURL),
                          settings: settings(entry.source.pluginID), revision: providerConfigurationRevision)
    }

    @discardableResult
    package func discoverTests(_ entryID: String) -> UUID? {
        guard let workspaceURL, let entry = entry(entryID), entry.declaration.testDiscovery else { return nil }
        testDiscoveries[entryID] = nil
        discoverySnapshots[entryID] = nil
        return startRun(entryID, title: L10n.string("Discover Tests")) { service, run in
            let context = try service.planContext(entry, workspaceURL: workspaceURL)
            let request = try service.planner.testDiscoveryPlan(entry.target, context: context)
            let isValid = service.runValidity(.provider(request), entry: entry, workspaceURL: workspaceURL, run: run)
            service.providerRunID = run.id
            service.discoverySnapshots[entryID] = service.discoverySnapshot(entry, workspaceURL: workspaceURL)
            service.testDiscoveries[entryID] = .loading
            defer { if service.providerRunID == run.id { service.providerRunID = nil } }
            do {
                guard let providers = service.providers else { throw BuildSystemServiceError(Self.providerUnsupportedMessage) }
                let planned = try await service.providerRequestWithTool(request, entry: entry, workspaceURL: workspaceURL, run: run)
                guard isValid() else { throw CancellationError() }
                let result = try await providers.send(planned, to: Self.providerTarget(entry, workspaceURL: workspaceURL),
                                                      timeout: Self.modelTimeout)
                guard isValid() else { throw CancellationError() }
                let planner = service.planner
                let discovery = try await Task.detached(priority: .userInitiated) {
                    try planner.decodeTestDiscovery(entry.target, context: context, result: result)
                }.value
                guard isValid() else { throw CancellationError() }
                service.testDiscoveries[entryID] = .loaded(discovery)
                return 0
            } catch {
                if isValid() { service.testDiscoveries[entryID] = .failed(error.localizedDescription) }
                else if service.runID == run.id { service.testDiscoveries[entryID] = nil }
                throw error
            }
        }
    }

    @discardableResult
    package func runDiscoveredTest(_ entryID: String, testID: String, title: String) -> UUID? {
        guard case .loaded(let discovery) = testDiscovery(entryID),
              let test = discovery.tests.first(where: { $0.id == testID }) else { return nil }
        let request = BuildTestRequest(project: test.project, target: test.target,
                                       suite: test.suite, testCase: test.testCase,
                                       projects: entry(entryID)?.model?.projects.map(\.path) ?? [])
        return runTests(entryID, request: request, title: title)
    }

    /// Runs a declared task, or a model task through its template.
    @discardableResult
    package func runTask(_ entryID: String, request: BuildTaskRequest, title: String) -> UUID? {
        guard let workspaceURL, let entry = entry(entryID) else { return nil }
        return startRun(entryID, title: title) { service, run in
            let context = try service.planContext(entry, workspaceURL: workspaceURL)
            let plan = try service.planner.taskPlan(entry.target, context: context, request: request)
            let isValid = service.runValidity(plan, entry: entry, workspaceURL: workspaceURL, run: run)
            defer { if service.providerRunID == run.id { service.providerRunID = nil } }
            let collected = try await service.runExecutionPlan(plan, entry: entry, workspaceURL: workspaceURL, run: run)
            let diagnostics = await service.decodeDiagnostics(entry, workspaceURL: workspaceURL, output: collected.text)
            // The decode runs after the command; a stop, replacement, or
            // workspace switch in between must not publish into the new state.
            guard isValid() else { throw CancellationError() }
            service.diagnostics = diagnostics
            return collected.exitCode
        }
    }

    @discardableResult
    package func runTests(_ entryID: String, request: BuildTestRequest, title: String) -> UUID? {
        guard let workspaceURL, let entry = entry(entryID) else { return nil }
        return startRun(entryID, title: title) { service, run in
            let context = try service.planContext(entry, workspaceURL: workspaceURL)
            let plan = try service.planner.testPlan(entry.target, context: context, request: request)
            let isValid = service.runValidity(plan.execution, entry: entry, workspaceURL: workspaceURL, run: run)
            defer { if service.providerRunID == run.id { service.providerRunID = nil } }
            if plan.results != nil, request.project == nil,
               entry.instance.modelSource != nil,
               entry.model == nil || entry.isReloadRequired {
                // Report globs are relative to each project; without a current
                // model a new subproject's reports are invisible and a failing
                // run would decode as success. A plugin without a model has no
                // projects to discover, so its own reports stay readable.
                throw BuildSystemServiceError(L10n.string(
                    "Load or reload the project model before running all tests, so subproject reports are collected."
                ))
            }
            let started = Date()
            let collected = try await service.runExecutionPlan(
                plan.execution, entry: entry, workspaceURL: workspaceURL, run: run
            )
            let diagnostics = await service.decodeDiagnostics(entry, workspaceURL: workspaceURL, output: collected.text)
            guard isValid() else { throw CancellationError() }
            service.diagnostics = diagnostics
            if plan.results != nil {
                let resultsRequest = BuildTestResultsRequest(
                    workspaceURL: workspaceURL,
                    root: entry.instance.root,
                    project: request.project?.path,
                    projects: request.projects,
                    output: collected.text,
                    notBefore: started,
                    suite: request.suite
                )
                let planner = service.planner
                let target = entry.target
                do {
                    let results = try await Task.detached(priority: .userInitiated) {
                        try planner.decodeTestResults(target, request: resultsRequest)
                    }.value
                    guard isValid() else { throw CancellationError() }
                    service.testResults = results
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard isValid() else { throw CancellationError() }
                    service.appendOutput(
                        "\n" + error.localizedDescription + "\n", in: service.outputDirectory(entry), owner: .run(run)
                    )
                }
            }
            return collected.exitCode
        }
    }

    /// Ends the task or test run. Model and dependency commands keep running.
    package func stopRun() {
        guard runTask != nil else { return }
        var ended: BuildRunEnd?
        if let runID, let runEntryID {
            ended = BuildRunEnd(runID: runID, entryID: runEntryID, state: .cancelled, exitCode: nil)
            if testDiscoveries[runEntryID] == .loading { testDiscoveries[runEntryID] = nil }
        }
        runTask?.cancel()
        runTask = nil
        providerRunID = nil
        preparingApplicationID = nil
        runID = nil
        runEntryID = nil
        if runState == .running {
            runState = .cancelled
        }
        if let ended, operation?.id == ended.runID { operation?.state = .cancelled }
        if let ended { runEnded.send(ended) }
    }

    /// Ends every process this service started.
    package func stop() {
        nativeConfiguration?.stop()
        stopPreparedApplication()
        detectionTask?.cancel(); detectionTask = nil
        detectionID = nil
        redetectTask?.cancel(); redetectTask = nil
        languageImport = nil
        languageImportFailure = nil
        isDetecting = false
        finishImportWaiters(.failure(CancellationError()))
        stopRun()
        testDiscoveries = [:]
        discoverySnapshots = [:]
        for task in modelTasks.values { task.cancel() }
        for task in dependencyTasks.values { task.cancel() }
        modelTasks = [:]
        dependencyTasks = [:]
        // Providers outlive their requests and must also end with the project session.
        providers?.retainProviders { _ in false }
        for index in entries.indices {
            if entries[index].modelState == .loading {
                entries[index].modelState = entries[index].model == nil ? .notLoaded : .loaded
            }
            entries[index].dependencies = entries[index].dependencies.filter { $0.value != .loading }
        }
    }

    package func clearOutput() {
        output = ""
        outputByteCount = 0
        outputRoots = []
        diagnostics = []
        testResults = nil
        operation?.output = ""
    }

    private func startRun(
        _ entryID: String,
        title: String,
        _ work: @escaping @MainActor (BuildSystemService, RunIdentity) async throws -> Int32?
    ) -> UUID {
        stopRun()
        clearOutput()
        let id = UUID()
        let run = RunIdentity(id: id, generation: generation)
        runID = id
        runEntryID = entryID
        runState = .running
        runningTitle = title
        operation = BuildOperationSnapshot(id: id, entryID: entryID, title: title,
                                           state: .running, exitCode: nil, output: "")
        runTask = Task { [weak self] in
            guard let self, self.isCurrent(run) else { return }
            let state: BuildRunState
            var exitCode: Int32?
            do {
                exitCode = try await work(self, run)
                if let exitCode {
                    state = exitCode == 0
                        ? .succeeded
                        : .failed(L10n.string("The build tool exited with code \(Int(exitCode))."))
                } else {
                    state = .failed(L10n.string("The build tool timed out."))
                }
            } catch is CancellationError {
                state = .cancelled
            } catch {
                if self.runID == id {
                    self.appendOutput(
                        error.localizedDescription + "\n", in: self.outputDirectory(entryID: entryID), owner: .run(run)
                    )
                }
                state = .failed(error.localizedDescription)
            }
            guard self.runID == id else { return }
            self.runState = state
            self.operation?.state = state
            self.operation?.exitCode = exitCode
            self.runTask = nil
            self.runID = nil
            self.runEntryID = nil
            self.runEnded.send(BuildRunEnd(runID: id, entryID: entryID, state: state, exitCode: exitCode))
        }
        return id
    }

    /// True while `run` is still the run whose results may be shown: same
    /// run ID, same workspace generation, and not cancelled.
    private func isCurrent(_ run: RunIdentity) -> Bool {
        runID == run.id && generation == run.generation && !Task.isCancelled
    }

    /// Whether the command's owner still exists. A cancelled command may keep
    /// draining its pipe after the run stopped or the workspace changed; its
    /// tail must not appear in the new Build Output.
    private func canAppend(_ owner: CommandOwner) -> Bool {
        switch owner {
        case .run(let run):
            return isCurrent(run)
        case .modelLoad(let generation, let entryID, let id):
            return generation == self.generation && modelTasks[entryID]?.id == id
        case .dependencyLoad(let generation, let taskKey, let id):
            return generation == self.generation && dependencyTasks[taskKey]?.id == id
        }
    }

    private func decodeDiagnostics(
        _ entry: BuildSystemEntry,
        workspaceURL: URL,
        output: String
    ) async -> [BuildDiagnostic] {
        let planner = planner
        let target = entry.target
        let root = entry.instance.root
        // A build system without a diagnostics declaration is refused with
        // `plugin.build.unavailable`; it simply reports nothing.
        return await Task.detached(priority: .utility) {
            (try? planner.decodeDiagnostics(target, workspaceURL: workspaceURL, root: root, output: output)) ?? []
        }.value
    }

    // MARK: Dependencies

    /// Lists the dependencies of one project, or of the instance.
    package func loadDependencies(
        _ entryID: String, project: BuildModel.Project?, reason: BuildLoadReason = .initial
    ) {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        let key = project?.path ?? entry.instance.root
        let taskKey = entryID + Self.dependencyTaskSeparator + key
        dependencyTasks[taskKey]?.cancel()
        update(entryID) { $0.dependencies[key] = .loading }
        let generation = generation
        let id = UUID()
        let optionFingerprint = optionFingerprint(entry, workspaceURL: workspaceURL)
        let startFileRevision = fileRevision
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performDependencyLoad(
                entry,
                project: project,
                workspaceURL: workspaceURL,
                reason: reason,
                owner: .dependencyLoad(generation: generation, taskKey: taskKey, id: id)
            )
            guard self.generation == generation, self.dependencyTasks[taskKey]?.id == id,
                  !Task.isCancelled else { return }
            self.dependencyTasks[taskKey] = nil
            let current = self.entry(entryID) ?? entry
            let configChanged = self.fileRevision != startFileRevision
                || self.optionFingerprint(current, workspaceURL: workspaceURL) != optionFingerprint
            self.update(entryID) {
                if configChanged {
                    // The tree answers the old option values; showing it under
                    // the new ones would silently mislead.
                    $0.dependencies[key] = .failed(String(
                        localized: "Options changed while loading dependencies. Load them again."
                    ))
                } else {
                    switch result {
                    case .success(let tree): $0.dependencies[key] = .loaded(tree)
                    case .failure(let error) where error is CancellationError: $0.dependencies[key] = nil
                    case .failure(let error): $0.dependencies[key] = .failed(error.localizedDescription)
                    }
                }
            }
            self.noteDependenciesChanged(entryID)
        }
        dependencyTasks[taskKey] = LoadTask(id: id, task: task)
    }

    private func performDependencyLoad(
        _ entry: BuildSystemEntry,
        project: BuildModel.Project?,
        workspaceURL: URL,
        reason: BuildLoadReason,
        owner: CommandOwner
    ) async -> Result<BuildDependencyTree, Error> {
        do {
            let context = try planContext(entry, workspaceURL: workspaceURL)
            let outputFile = try context.workspaceStateDirectory.map { try stateLocator.allocateOutputFile(in: $0) }
            defer { if let outputFile { stateLocator.removeOutputFile(outputFile) } }
            let planner = planner
            let selection = project.map(BuildSelection.init(project:))
            let plan = try await outputPlan(entry, workspaceURL: workspaceURL, reason: reason, owner: owner) { hints in
                try planner.dependencyPlan(
                    entry.target, context: context, project: selection, outputFile: outputFile, providerHints: hints
                )
            }
            let name = project?.displayName ?? project?.name ?? entry.instance.displayName
            let output = try await captureOutput(
                plan,
                entry: entry,
                workspaceURL: workspaceURL,
                outputFile: outputFile,
                title: L10n.string("Loading dependencies of \(name)"),
                timeout: Self.modelTimeout,
                owner: owner
            )
            let target = entry.target
            let root = entry.instance.root
            let loaded = try await Task.detached(priority: .userInitiated) {
                try planner.decodeDependencies(
                    target, workspaceURL: workspaceURL, root: root, project: project?.path, output: output
                )
            }.value
            guard modelInputsAreCurrent(context.modelInputs) else { throw CancellationError() }
            return .success(loaded)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Options

    /// Stores one option value, or removes it with nil, for every instance
    /// of the build system in this workspace.
    // MARK: Plugin functions

    /// The plugin functions the instance's provider process registers now,
    /// starting the process when none runs. Callers ask the user first, as
    /// for any request that starts a build tool.
    package func pluginFunctions(_ entryID: String) async throws -> [String] {
        let (providers, target) = try functionTarget(entryID)
        return try await providers.pluginFunctions(of: target)
    }

    /// Invokes a plugin function in the instance's provider process. The
    /// function belongs to the instance's plugin, which Core checks again
    /// against the process owner; cancelling the task cancels the call.
    package func invokePluginFunction(
        _ entryID: String,
        functionID: String,
        params: ToolingJSONValue,
        timeout: Duration,
        progress: @escaping @MainActor @Sendable (PluginFunctionProgress) -> Void
    ) async throws -> ToolingJSONValue {
        let (providers, target) = try functionTarget(entryID)
        return try await providers.invokePluginFunction(
            functionID, params: params, on: target, timeout: timeout, progress: progress
        )
    }

    private func functionTarget(_ entryID: String) throws -> (any BuildProviderRequesting, BuildProviderTarget) {
        guard let workspaceURL, let entry = entry(entryID) else {
            throw PluginFunctionFailure(
                code: "plugin.function.unavailable",
                message: L10n.string("The build-system instance is no longer detected.")
            )
        }
        guard let providers else { throw BuildSystemServiceError(Self.providerUnsupportedMessage) }
        return (providers, Self.providerTarget(entry, workspaceURL: workspaceURL))
    }

    private static func providerTarget(_ entry: BuildSystemEntry, workspaceURL: URL) -> BuildProviderTarget {
        BuildProviderTarget(
            pluginID: entry.source.pluginID,
            manifest: entry.source.manifest,
            packageURL: entry.source.packageURL,
            buildSystemID: entry.instance.buildSystemID,
            workspaceURL: workspaceURL
        )
    }

    package func setOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) {
        do { try writeOption(entryID, optionID: optionID, value: value) }
        catch { issues.append(error.localizedDescription) }
    }

    private func writeOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) throws {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        let buildSystemID = entry.instance.buildSystemID
        nativeOptionsRevisions[buildSystemID, default: 0] += 1
        nativeConfiguration?.invalidate(buildSystemID: buildSystemID)
        invalidateTestDiscovery(buildSystemID: buildSystemID)
        if providerRunID != nil, let runEntryID, self.entry(runEntryID)?.instance.buildSystemID == buildSystemID {
            stopRun()
        }
        if entry.declaration.options.first(where: { $0.id == optionID })?.scope == .instance {
            var instances = try optionsStore.instanceOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            var stored = instances[entry.instance.root] ?? [:]
            stored[optionID] = value
            instances[entry.instance.root] = stored.isEmpty ? nil : stored
            try optionsStore.setInstanceOptions(instances, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        } else {
            var stored = try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            stored[optionID] = value
            var empty = try optionsStore.emptyMultiSelectOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            for root in Array(empty.keys) {
                empty[root]?.remove(optionID)
                if empty[root]?.isEmpty == true { empty[root] = nil }
            }
            try optionsStore.setEmptyMultiSelectOptions(empty, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            try optionsStore.setOptions(stored, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        }
        try refreshOptions(buildSystemID: buildSystemID)
        if entry.declaration.sharesModel {
            invalidateProducerConfiguration(buildSystemID: buildSystemID)
        }
        // The options take part in the sync fingerprint, so a changed value
        // marks a loaded command model stale.
        detect()
    }

    /// An instance editor preserves sibling-only choices in the shared value.
    /// Explicit empty selections also need an instance marker: sibling-only
    /// values would otherwise be rejected by Core and revive a non-empty default.
    /// Reset still removes the option's complete shared and instance overrides.
    package func setInstanceOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) {
        do { try writeInstanceOption(entryID, optionID: optionID, value: value) }
        catch { issues.append(error.localizedDescription) }
    }

    private func writeInstanceOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) throws {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        if entry.declaration.options.first(where: { $0.id == optionID })?.scope == .instance {
            try writeOption(entryID, optionID: optionID, value: value)
            return
        }
        guard case .array(let next)? = value,
              let option = entry.options.first(where: { $0.id == optionID }), option.kind == .multiSelect,
              case .array(let visible) = option.value else {
            try writeOption(entryID, optionID: optionID, value: value)
            return
        }
        let buildSystemID = entry.instance.buildSystemID
        nativeOptionsRevisions[buildSystemID, default: 0] += 1
        nativeConfiguration?.invalidate(buildSystemID: buildSystemID)
        invalidateTestDiscovery(buildSystemID: buildSystemID)
        if providerRunID != nil, let runEntryID, self.entry(runEntryID)?.instance.buildSystemID == buildSystemID {
            stopRun()
        }
        var stored = try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        let values: [ToolingJSONValue]
        if case .array(let items)? = stored[optionID] { values = items } else { values = [] }
        let siblingValues = values.filter { !visible.contains($0) }
        stored[optionID] = .array(siblingValues + next.filter { !siblingValues.contains($0) })
        var empty = try optionsStore.emptyMultiSelectOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        let root = entry.instance.root
        if next.isEmpty {
            empty[root, default: []].insert(optionID)
        } else {
            empty[root]?.remove(optionID)
            if empty[root]?.isEmpty == true { empty[root] = nil }
        }
        try optionsStore.setEmptyMultiSelectOptions(empty, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        try optionsStore.setOptions(stored, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        try refreshOptions(buildSystemID: buildSystemID)
        if entry.declaration.sharesModel {
            invalidateProducerConfiguration(buildSystemID: buildSystemID)
        }
        detect()
    }

    private func invalidateTestDiscovery(buildSystemID: String) {
        for entry in entries where entry.instance.buildSystemID == buildSystemID {
            testDiscoveries[entry.id] = nil
            discoverySnapshots[entry.id] = nil
        }
    }

    /// A declaration upgrade can move a previously shared option to instance
    /// scope. Copy every detected root first, preserve existing local choices,
    /// and prove the destination before removing any source value. A second
    /// detection then generates static models with the migrated input.
    private func migrateInstanceOptions(entries: [BuildSystemEntry], workspaceURL: URL) throws -> Bool {
        var changed = false
        for buildSystemID in Set(entries.map(\.instance.buildSystemID)).sorted() {
            let instances = entries.filter { $0.instance.buildSystemID == buildSystemID }
            guard let declaration = instances.first?.declaration else { continue }
            let shared = try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            let moving = Set(declaration.options.filter { $0.scope == .instance && shared[$0.id] != nil }.map(\.id))
            guard !moving.isEmpty else { continue }
            var local = try optionsStore.instanceOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            var empty = try optionsStore.emptyMultiSelectOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            let roots = Set(instances.map(\.instance.root)).union(empty.keys).union(local.keys)
            let multiSelect = Set(instances.first?.options.filter { $0.kind == .multiSelect }.map(\.id) ?? [])
            for root in roots.sorted() {
                for id in moving where local[root]?[id] == nil {
                    let isCleared = empty[root]?.contains(id) == true && multiSelect.contains(id)
                    local[root, default: [:]][id] = isCleared ? .array([]) : shared[id]
                }
            }
            try optionsStore.setInstanceOptions(local, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            guard try optionsStore.instanceOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID) == local,
                  try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID) == shared else {
                throw BuildSystemServiceError(L10n.string("Build option migration could not be verified. The previous configuration has been retained. Reload the build instance to retry."))
            }
            let remaining = shared.filter { !moving.contains($0.key) }
            try optionsStore.setOptions(remaining, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            guard try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID) == remaining else {
                throw BuildSystemServiceError(L10n.string("Build option migration could not be verified. The previous configuration has been retained. Reload the build instance to retry."))
            }
            for root in Array(empty.keys) {
                empty[root]?.subtract(moving)
                if empty[root]?.isEmpty == true { empty[root] = nil }
            }
            try optionsStore.setEmptyMultiSelectOptions(empty, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
            changed = true
        }
        return changed
    }

    /// Choices are presentation data, never selected values or model facts.
    private func restoreSavedChoices(workspaceURL: URL) throws {
        for system in Set(entries.map(\.instance.buildSystemID)).sorted() {
            let saved = try optionsStore.savedChoices(workspaceURL: workspaceURL, buildSystemID: system)
            for index in entries.indices where entries[index].instance.buildSystemID == system {
                for option in entries[index].options.indices where entries[index].options[option].allowCustom {
                    let existing = Set(entries[index].options[option].choices.map(\.value))
                    let id = entries[index].options[option].id
                    entries[index].options[option].choices += Array(Set(saved[id] ?? [])).sorted()
                        .filter { !existing.contains($0) }.map { BuildResolvedOption.Choice(value: $0) }
                }
            }
        }
    }

    private func refreshOptions(buildSystemID: String) throws {
        guard let workspaceURL else { return }
        let stored = try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        let empty = try optionsStore.emptyMultiSelectOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        var instances = try optionsStore.instanceOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        let defaults = try optionsStore.instanceDefaults(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        let originalInstances = instances
        var resolutions: [BuildOptionsResolution] = []
        for index in entries.indices where entries[index].instance.buildSystemID == buildSystemID {
            let entry = entries[index]
            guard let resolution = try? planner.resolveOptions(
                entry.target, options: stored, modelValues: entry.model?.optionValues
            ) else { continue }
            // Shared storage is pruned against the shared value, never an
            // empty instance override that could hide a sibling's valid choice.
            resolutions.append(resolution)
            let scoped = Self.scopedOptions(
                declaration: entry.declaration, workspace: stored,
                instance: defaults.merging(instances[entry.instance.root] ?? [:]) { _, root in root }
            )
            let input = Self.applyingEmptySelections(
                to: scoped, optionIDs: empty[entry.instance.root] ?? [], options: resolution.options
            )
            let effective = input == stored ? resolution : (
                try? planner.resolveOptions(entry.target, options: input, modelValues: entry.model?.optionValues)
            ) ?? resolution
            entries[index].options = effective.options
            if let local = instances[entry.instance.root] {
                let declared = Set(entry.declaration.options.filter { $0.scope == .instance }.map(\.id))
                let pruned = Self.mergedOptionValues(stored: local.filter { declared.contains($0.key) }, resolutions: [effective])
                instances[entry.instance.root] = pruned.isEmpty ? nil : pruned
            }
        }
        // Options are stored per workspace and build system, but a model
        // value is valid for one instance. Keep a value as long as any
        // instance still accepts it; each plan filters it against its own
        // model, so one instance cannot delete another's selection.
        let merged = Self.mergedOptionValues(stored: stored, resolutions: resolutions)
        if merged != stored {
            try optionsStore.setOptions(merged, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        }
        if instances != originalInstances {
            try optionsStore.setInstanceOptions(instances, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        }
        try restoreSavedChoices(workspaceURL: workspaceURL)
    }

    /// Stored values reduced to the ones at least one instance still accepts.
    /// Multi-select entries no instance accepts are removed; a scalar stays
    /// when any instance accepts it.
    nonisolated private static func mergedOptionValues(
        stored: [String: ToolingJSONValue],
        resolutions: [BuildOptionsResolution]
    ) -> [String: ToolingJSONValue] {
        guard !resolutions.isEmpty else { return stored }
        var declared: Set<String> = []
        var multiSelect: Set<String> = []
        var chosen: Set<String> = []
        var accepted: [String: [ToolingJSONValue]] = [:]
        for resolution in resolutions {
            for option in resolution.options {
                declared.insert(option.id)
                if option.kind == .multiSelect { multiSelect.insert(option.id) }
                guard option.source == "user" else { continue }
                chosen.insert(option.id)
                if option.kind == .multiSelect, case .array(let items) = option.value {
                    accepted[option.id, default: []].append(contentsOf: items)
                } else {
                    accepted[option.id, default: []].append(option.value)
                }
            }
        }
        var merged: [String: ToolingJSONValue] = [:]
        for (id, value) in stored {
            guard declared.contains(id) else { continue }
            let values = accepted[id] ?? []
            if multiSelect.contains(id) {
                guard case .array(let items) = value else { continue }
                var kept: [ToolingJSONValue] = []
                for item in items where values.contains(item) && !kept.contains(item) {
                    kept.append(item)
                }
                if !kept.isEmpty {
                    merged[id] = .array(kept)
                } else if chosen.contains(id) {
                    // The user cleared every remaining choice; an empty
                    // selection is a value, so a non-empty default must not
                    // come back on the next detection.
                    merged[id] = .array([])
                }
            } else if values.contains(value) {
                merged[id] = value
            }
        }
        return merged
    }

    /// Stores the effective values Core reported after detection, so a value
    /// the current model removed cannot stay in the options of the next plan.
    private func persistDroppedOptions() throws {
        for buildSystemID in Set(entries.map(\.instance.buildSystemID)) {
            try refreshOptions(buildSystemID: buildSystemID)
        }
    }

    private func storedOptions(for entry: BuildSystemEntry, workspaceURL: URL) throws -> [String: ToolingJSONValue] {
        let buildSystemID = entry.instance.buildSystemID
        return Self.applyingEmptySelections(
            to: Self.scopedOptions(
                declaration: entry.declaration,
                workspace: try optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID),
                instance: try optionsStore.instanceDefaults(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
                    .merging(optionsStore.instanceOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)[entry.instance.root] ?? [:]) { _, root in root }
            ),
            optionIDs: try optionsStore.emptyMultiSelectOptions(workspaceURL: workspaceURL, buildSystemID: buildSystemID)[entry.instance.root] ?? [],
            options: entry.options
        )
    }

    /// A scope is an ownership boundary: workspace values never act as hidden
    /// overrides for instance options, nor can local data replace shared options.
    nonisolated private static func scopedOptions(
        declaration: DeclarativeBuildSystem,
        workspace: [String: ToolingJSONValue], instance: [String: ToolingJSONValue]
    ) -> [String: ToolingJSONValue] {
        var values = workspace
        for option in declaration.options where option.scope == .instance {
            values[option.id] = instance[option.id]
        }
        return values
    }

    nonisolated private static func applyingEmptySelections(
        to stored: [String: ToolingJSONValue], optionIDs: Set<String>, options: [BuildResolvedOption]
    ) -> [String: ToolingJSONValue] {
        var values = stored
        // A plugin update may change the kind; an old empty marker must not
        // turn a text or boolean option into an array.
        for option in options where option.scope == .workspace && option.kind == .multiSelect && optionIDs.contains(option.id) {
            values[option.id] = .array([])
        }
        return values
    }

    // MARK: Commands

    /// Agent and native callers share the instance editor. Invalid values must
    /// fail before storage rather than silently reverting to a default.
    package func configureOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) throws -> BuildResolvedOption {
        guard let workspaceURL, let entry = entry(entryID), entry.options.contains(where: { $0.id == optionID }) else {
            throw BuildSystemServiceError(L10n.string("The build option is no longer available. Reload the build instance."))
        }
        var proposed = try storedOptions(for: entry, workspaceURL: workspaceURL)
        proposed[optionID] = value
        let resolution = try planner.resolveOptions(entry.target, options: proposed, modelValues: entry.model?.optionValues)
        guard let accepted = resolution.options.first(where: { $0.id == optionID }),
              !resolution.dropped.contains(optionID), value == nil || accepted.value == value else {
            throw BuildSystemServiceError(L10n.string("The build option value is invalid. Inspect its current kind and choices."))
        }
        try writeInstanceOption(entryID, optionID: optionID, value: value)
        guard let saved = self.entry(entryID)?.options.first(where: { $0.id == optionID }), value == nil || saved.value == accepted.value else {
            throw BuildSystemServiceError(L10n.string("The saved build option could not be verified. Reload before editing again."))
        }
        return saved
    }

    private func optionFingerprint(_ entry: BuildSystemEntry, workspaceURL: URL) -> String? {
        guard let stored = try? storedOptions(for: entry, workspaceURL: workspaceURL) else { return nil }
        return (try? planner.resolveOptions(
            entry.target, options: stored, modelValues: entry.model?.optionValues
        ))?.fingerprint
    }

    private func planContext(_ entry: BuildSystemEntry, workspaceURL: URL) throws -> BuildPlanContext {
        let stored = try storedOptions(for: entry, workspaceURL: workspaceURL)
        let resolution = try? planner.resolveOptions(
            entry.target, options: stored, modelValues: entry.model?.optionValues
        )
        return BuildPlanContext(
            root: entry.instance.root,
            // A plan gets only values Core still accepts for the current
            // model; otherwise a removed Cargo feature would reach the argv.
            options: Self.effectiveOptionValues(resolution, stored: stored),
            pluginDirectory: entry.source.packageURL,
            workspaceStateDirectory: try stateLocator.workspaceStateDirectory(
                pluginID: entry.instance.pluginID,
                buildSystemID: entry.instance.buildSystemID,
                workspaceURL: workspaceURL
            ),
            modelInputs: try resolvedModelInputs(entry, workspaceURL: workspaceURL)
        )
    }

    private func resolvedModelInputs(_ consumer: BuildSystemEntry, workspaceURL: URL) throws -> ToolingJSONValue? {
        guard !consumer.declaration.modelInputs.isEmpty else { return nil }
        let enabled = sources()
        let required = Set(consumer.declaration.modelInputs.map(\.pluginID))
        let facts = try enabled.filter { required.contains($0.pluginID) }.map { source in
            BuildModelInputSource(manifest: source.manifest, instances: try entries.filter { $0.source == source && $0.declaration.sharesModel }.map { producer in
                let state: String
                switch producer.modelState {
                case .loading: state = "loading"
                case .failed: state = "failed"
                case .loaded where !producer.isReloadRequired && producer.model != nil: state = "ready"
                default: state = "stale"
                }
                return BuildModelInputSource.Instance(buildSystemID: producer.instance.buildSystemID, root: producer.instance.root,
                    state: state, model: state == "ready" ? producer.model : nil, options: try storedOptions(for: producer, workspaceURL: workspaceURL))
            })
        }
        return try planner.resolveModelInputs(consumer.target, revision: modelInputRevision, sources: facts)
    }

    private func modelInputsAreCurrent(_ snapshot: ToolingJSONValue?) -> Bool {
        guard let snapshot else { return true }
        guard case .object(let value) = snapshot, case .integer(let revision) = value["revision"] else { return false }
        return revision >= 0 && UInt64(revision) == modelInputRevision
    }

    private func modelInputsAreCurrent(_ request: BuildProviderRequest) -> Bool {
        guard case .object(let params) = request.params else { return false }
        return modelInputsAreCurrent(params["modelInputs"])
    }

    /// Producers are independent in v1: consumers cannot re-export their inputs.
    /// Revoke consumers immediately; cancellation-ignoring replies still fail revision checks.
    private func invalidateModelInputs() {
        modelInputRevision += 1
        let consumers = Set(entries.filter { !$0.declaration.modelInputs.isEmpty }.map(\.id))
        if let runEntryID, consumers.contains(runEntryID) { stopRun() }
        for id in consumers {
            modelTasks.removeValue(forKey: id)?.cancel()
            for key in Array(dependencyTasks.keys) where Self.entryID(ofDependencyTask: key) == id {
                dependencyTasks.removeValue(forKey: key)?.cancel()
            }
            update(id) {
                $0.isReloadRequired = $0.model != nil
                if $0.modelState == .loading { $0.modelState = $0.model == nil ? .notLoaded : .loaded }
                $0.dependencies = [:]
            }
            modelRevisions[id, default: 0] += 1
            testDiscoveries[id] = nil
            discoverySnapshots[id] = nil
        }
    }

    private func invalidateProducerConfiguration(buildSystemID: String) {
        for producer in entries where producer.instance.buildSystemID == buildSystemID {
            if producer.declaration.sharesModel { modelConfigurationRevisions[producer.id, default: 0] += 1 }
            update(producer.id) { $0.isReloadRequired = true }
        }
        invalidateModelInputs()
    }

    /// Stored values reduced to the ones Core accepted in `resolution`. Core
    /// applies declaration defaults itself, so plans and fingerprints receive
    /// only effective user choices and never a value the current model removed.
    nonisolated private static func effectiveOptionValues(
        _ resolution: BuildOptionsResolution?,
        stored: [String: ToolingJSONValue]
    ) -> [String: ToolingJSONValue] {
        guard let resolution else { return stored }
        var values: [String: ToolingJSONValue] = [:]
        for option in resolution.options where option.source == "user" {
            values[option.id] = option.value
        }
        return values
    }

    private func commandRequest(
        _ plan: BuildProcessPlan,
        entry: BuildSystemEntry,
        workspaceURL: URL,
        capturesStandardOutput: Bool,
        timeout: Duration?
    ) async throws -> BuildCommandRequest {
        let planner = planner
        let target = entry.target
        let invocation = try planner.invocationPlan(
            target, root: entry.instance.root, settings: settings(entry.source.pluginID)
        )
        let tool = try await tools.resolve(
            invocation,
            displayName: entry.instance.displayName,
            workspaceURL: workspaceURL
        ) { runtime, output in
            try planner.checkToolVersion(target, runtime: runtime, output: output)
        }
        try Task.checkCancellation()
        return BuildCommandRequest(
            executableURL: tool.executableURL,
            arguments: plan.arguments,
            workingDirectory: workspaceURL.appendingPathComponent(plan.workingDirectory).standardizedFileURL,
            environment: tool.environment.merging(plan.environment) { _, contribution in contribution },
            capturesStandardOutput: capturesStandardOutput,
            timeout: timeout
        )
    }

    private struct CollectedOutput {
        let text: String
        /// Nil when the command timed out.
        let exitCode: Int32?
    }

    /// Runs a task or test command; its output is the run's output.
    private func runStreamedCommand(
        _ plan: BuildProcessPlan,
        entry: BuildSystemEntry,
        workspaceURL: URL,
        owner: CommandOwner
    ) async throws -> CollectedOutput {
        let request = try await commandRequest(
            plan, entry: entry, workspaceURL: workspaceURL, capturesStandardOutput: false, timeout: nil
        )
        let directory = outputDirectory(entry)
        if canAppend(owner) { appendOutput(Self.commandLine(request), in: directory, owner: owner) }
        let collector = OutputCollector(limit: Self.decodedOutputLimit)
        let result = try await run(request, owner: owner) { [weak self] chunk in
            collector.append(chunk)
            self?.appendOutput(chunk, in: directory, owner: owner)
        }
        let exitCode: Int32? = switch result.termination {
        case .exited(let code): code
        case .timedOut: nil
        }
        return CollectedOutput(text: collector.text, exitCode: exitCode)
    }

    /// Retain the provider configuration guard through every asynchronous decode,
    /// including report parsing after the backend has already returned.
    private func runValidity(
        _ plan: BuildOutputPlan, entry: BuildSystemEntry, workspaceURL: URL, run: RunIdentity
    ) -> @MainActor @Sendable () -> Bool {
        let revision = providerConfigurationRevision
        let launchSettings = settings(entry.source.pluginID)
        return { [weak self] in
            guard let self, self.isCurrent(run) else { return false }
            guard case .provider(let request) = plan else { return true }
            guard self.modelInputsAreCurrent(request), self.providerConfigurationRevision == revision,
                  self.settings(entry.source.pluginID) == launchSettings,
                  let current = self.entry(entry.id), current.source == entry.source else { return false }
            return self.optionFingerprint(current, workspaceURL: workspaceURL) == request.optionFingerprint
        }
    }

    private func runExecutionPlan(
        _ plan: BuildOutputPlan, entry: BuildSystemEntry, workspaceURL: URL, run: RunIdentity
    ) async throws -> CollectedOutput {
        switch plan {
        case .process(let process):
            return try await runStreamedCommand(process, entry: entry, workspaceURL: workspaceURL, owner: .run(run))
        case .provider(let request):
            return try await runProviderTask(request, entry: entry, workspaceURL: workspaceURL, run: run)
        }
    }

    /// Provider tasks share model/dependency sessions, not plugin page sessions.
    /// Progress/results are bound to this run and its effective configuration.
    private func runProviderTask(
        _ request: BuildProviderRequest, entry: BuildSystemEntry, workspaceURL: URL, run: RunIdentity
    ) async throws -> CollectedOutput {
        guard let providers else { throw BuildSystemServiceError(Self.providerUnsupportedMessage) }
        providerRunID = run.id
        let isValid = runValidity(.provider(request), entry: entry, workspaceURL: workspaceURL, run: run)
        let planned = try await providerRequestWithTool(request, entry: entry, workspaceURL: workspaceURL, run: run)
        guard isValid() else { throw CancellationError() }
        let directory = outputDirectory(entry)
        let streamed = OutputCollector(limit: Self.decodedOutputLimit)
        let result = try await providers.execute(
            planned, on: Self.providerTarget(entry, workspaceURL: workspaceURL), timeout: .seconds(3600)
        ) { [weak self] progress in
            guard let self, isValid() else { return }
            if let text = progress.output {
                streamed.append(text)
                self.appendOutput(text, in: directory, owner: .run(run))
            } else if let message = progress.message {
                self.appendOutput(message + "\n", in: directory, owner: .run(run))
            }
        }
        guard isValid() else { throw CancellationError() }
        if result.output.utf8.starts(with: streamed.text.utf8) {
            appendOutput(String(decoding: result.output.utf8.dropFirst(streamed.text.utf8.count), as: UTF8.self), in: directory, owner: .run(run))
        } else {
            // A malformed stream must not hide the final diagnostic output.
            appendOutput(result.output, in: directory, owner: .run(run))
        }
        return CollectedOutput(text: result.output, exitCode: result.exitCode)
    }

    private func providerRequestWithTool(
        _ request: BuildProviderRequest, entry: BuildSystemEntry, workspaceURL: URL, run: RunIdentity
    ) async throws -> BuildProviderRequest {
        let tool = try await providerTool(entry, workspaceURL: workspaceURL, owner: .run(run))
        var params = request.params
        if let tool, case .object(var object) = params {
            object["tool"] = .object(["executable": .string(tool.executableURL.path)])
            var environment = tool.providerEnvironment.mapValues(ToolingJSONValue.string)
            if case .object(let options)? = object["environment"] { environment.merge(options) { _, contribution in contribution } }
            object["environment"] = .object(environment)
            params = .object(object)
        }
        return BuildProviderRequest(method: request.method, params: params, optionFingerprint: request.optionFingerprint,
                                    executesProjectCode: request.executesProjectCode, mayUseNetwork: request.mayUseNetwork)
    }

    /// Plans a model or dependency load. A provider request also carries the
    /// load reason and the build tool the host resolved, so the provider
    /// neither repeats the lookup nor answers a reload from a stale snapshot.
    /// The tool is only resolved once Core says the source is a provider; a
    /// command plan resolves it when it runs.
    private func outputPlan(
        _ entry: BuildSystemEntry,
        workspaceURL: URL,
        reason: BuildLoadReason,
        owner: CommandOwner,
        plan: (BuildProviderHints) throws -> BuildOutputPlan
    ) async throws -> BuildOutputPlan {
        let planned = try plan(BuildProviderHints(reason: reason))
        guard case .provider = planned else { return planned }
        guard let executable = try await providerTool(entry, workspaceURL: workspaceURL, owner: owner) else {
            return planned
        }
        return try plan(BuildProviderHints(reason: reason, toolExecutable: executable.executableURL, toolEnvironment: executable.providerEnvironment))
    }

    /// The executable the build system's invocation resolves to, as a run
    /// would use it. Automatic discovery may fall back to the provider's lookup;
    /// an explicit selection must fail rather than use a different installation.
    private func providerTool(_ entry: BuildSystemEntry, workspaceURL: URL, owner: CommandOwner) async throws -> ResolvedBuildTool? {
        let planner = planner
        let target = entry.target
        let invocation = try planner.invocationPlan(
            target, root: entry.instance.root, settings: settings(entry.source.pluginID)
        )
        do {
            guard !invocation.executables.isEmpty else { return nil }
            return try await tools.resolve(
                invocation, displayName: entry.instance.displayName, workspaceURL: workspaceURL
            ) { runtime, output in
                try planner.checkToolVersion(target, runtime: runtime, output: output)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Runtime resolution can fail before the selected tool is visited.
            // Delegating then would lose the invocation's explicit selection.
            if invocation.hasExplicitExecutableSelection || (error as? BuildToolResolutionError)?.terminal == true { throw error }
            if canAppend(owner) {
                appendOutput(
                    "\n" + L10n.string("The provider looks up the build tool itself: \(error.localizedDescription)") + "\n",
                    in: outputDirectory(entry), owner: owner
                )
            }
            return nil
        }
    }

    /// Runs a model or dependency plan: its command, or its request to the
    /// plugin's provider process.
    private func captureOutput(
        _ plan: BuildOutputPlan,
        entry: BuildSystemEntry,
        workspaceURL: URL,
        outputFile: URL?,
        title: String,
        timeout: Duration,
        owner: CommandOwner
    ) async throws -> BuildCommandOutput {
        switch plan {
        case .process(let process):
            return try await runCapturedCommand(
                process, entry: entry, workspaceURL: workspaceURL, outputFile: outputFile,
                title: title, timeout: timeout, owner: owner
            )
        case .provider(let request):
            guard let providers else { throw BuildSystemServiceError(Self.providerUnsupportedMessage) }
            if canAppend(owner) {
                appendOutput("\n▶ " + title + "\n→ " + request.method + "\n", in: outputDirectory(entry))
            }
            let target = Self.providerTarget(entry, workspaceURL: workspaceURL)
            guard modelInputsAreCurrent(request), canAppend(owner) else { throw CancellationError() }
            let result = try await providers.send(request, to: target, timeout: timeout)
            guard modelInputsAreCurrent(request), canAppend(owner), !Task.isCancelled else { throw CancellationError() }
            return .providerResult(result)
        }
    }

    private func runCapturedCommand(
        _ plan: BuildProcessPlan,
        entry: BuildSystemEntry,
        workspaceURL: URL,
        outputFile: URL?,
        title: String,
        timeout: Duration,
        owner: CommandOwner
    ) async throws -> BuildCommandOutput {
        let capturesStandardOutput = plan.output != .outputFile
        let request = try await commandRequest(
            plan, entry: entry, workspaceURL: workspaceURL,
            capturesStandardOutput: capturesStandardOutput, timeout: timeout
        )
        let directory = outputDirectory(entry)
        if canAppend(owner) {
            appendOutput("\n▶ " + title + "\n" + Self.commandLine(request), in: directory)
        }
        let tail = OutputCollector(limit: 64 * 1024, keepsTail: true)
        let result = try await run(request, owner: owner) { [weak self] chunk in
            tail.append(chunk)
            self?.appendOutput(chunk, in: directory)
        }
        switch result.termination {
        case .timedOut:
            throw BuildSystemServiceError(L10n.string("\(title) timed out."))
        case .exited(let code) where code != 0:
            let detail = tail.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = L10n.string("The build tool exited with code \(Int(code)).")
            throw BuildSystemServiceError(detail.isEmpty ? summary : summary + "\n" + Self.lastLines(detail))
        case .exited:
            break
        }
        if capturesStandardOutput {
            guard let text = result.standardOutput else {
                throw BuildSystemServiceError(L10n.string("The build tool output is too large or not UTF-8."))
            }
            return .stdout(text)
        }
        guard let outputFile else {
            throw BuildSystemServiceError(L10n.string("The build tool output is too large or not UTF-8."))
        }
        return .outputFile(outputFile)
    }

    /// Runs one command, delivering its output on the main actor in order.
    private func run(
        _ request: BuildCommandRequest,
        owner: CommandOwner,
        sink: @escaping @MainActor (String) -> Void
    ) async throws -> BuildCommandResult {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task { @MainActor in
            for await chunk in stream {
                // A cancelled command may flush output after its run ended.
                guard canAppend(owner) else { continue }
                sink(chunk)
            }
        }
        do {
            let result = try await runner.run(request) { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            return result
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }

    private func appendOutput(_ chunk: String, in directory: URL?, owner: CommandOwner? = nil) {
        guard !chunk.isEmpty else { return }
        if case .run(let run)? = owner, var snapshot = operation, snapshot.id == run.id, canAppend(.run(run)) {
            snapshot.output += chunk
            if snapshot.output.utf8.count > Self.visibleOutputLimit {
                snapshot.output = String(snapshot.output.suffix(Self.visibleOutputLimit / 2))
            }
            operation = snapshot
        }
        if let directory, !outputRoots.contains(directory) {
            outputRoots = (outputRoots + [directory]).sorted { $0.path < $1.path }
        }
        output += chunk
        outputByteCount += chunk.utf8.count
        if outputByteCount > Self.visibleOutputLimit {
            output = String(output.suffix(Self.visibleOutputLimit / 2))
            outputByteCount = output.utf8.count
        }
    }

    private func outputDirectory(_ entry: BuildSystemEntry) -> URL? {
        workspaceURL?.appendingPathComponent(entry.instance.root).standardizedFileURL
    }

    private func outputDirectory(entryID: String) -> URL? {
        entry(entryID).flatMap(outputDirectory)
    }

    private func refreshActivity() {
        let active = isRunning || isLoadingModel || isLoadingDependencies || nativeConfiguration?.isBusy == true
        if hasActiveWork != active { hasActiveWork = active }
    }

    private func update(_ entryID: String, _ change: (inout BuildSystemEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        change(&entries[index])
    }

    private func noteModelChanged(_ entryID: String) {
        modelRevisions[entryID, default: 0] += 1
        if entry(entryID)?.declaration.sharesModel == true { invalidateModelInputs() }
    }

    private func noteDependenciesChanged(_ entryID: String) {
        dependencyRevisions[entryID, default: 0] += 1
    }

    private static let dependencyTaskSeparator = "\u{1F}"

    private static func entryID(ofDependencyTask key: String) -> String {
        key.components(separatedBy: dependencyTaskSeparator).first ?? key
    }

    private static func commandLine(_ request: BuildCommandRequest) -> String {
        "$ " + ([request.executableURL.path] + request.arguments).map(Self.shellQuoted).joined(separator: " ") + "\n"
    }

    private static func shellQuoted(_ argument: String) -> String {
        let plain = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
        return plain && !argument.isEmpty ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func lastLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(20).joined(separator: "\n")
    }

    private static var providerUnsupportedMessage: String {
        L10n.string("This build system answers through a provider process, which this build of Lithe cannot start.")
    }

    // MARK: Detection

    private struct Detected: Sendable {
        let entries: [BuildSystemEntry]
        let issues: [String]
    }

    nonisolated private static func detectEntries(
        planner: any BuildSystemPlanning,
        workspaceURL: URL,
        sources: [BuildSystemPluginSource],
        storedOptions: [String: [String: ToolingJSONValue]],
        instanceOptions: [String: [String: [String: ToolingJSONValue]]],
        instanceDefaults: [String: [String: ToolingJSONValue]],
        emptyMultiSelectOptions: [String: [String: Set<String>]],
        previous: [String: BuildSystemEntry]
    ) throws -> Detected {
        let detection = try planner.detect(workspaceURL: workspaceURL, sources: sources, options: storedOptions, instanceOptions: instanceOptions, instanceDefaults: instanceDefaults)
        var issues = detection.rejected.map { rejected in
            let pluginID = sources.indices.contains(rejected.index) ? sources[rejected.index].pluginID : "?"
            return "\(pluginID): \(rejected.error.message)"
        }
        issues += detection.shadowed.map {
            L10n.string("\($0.buildSystemID) of \($0.pluginID) is handled by \($0.by).")
        }
        let entries = detection.instances.compactMap { instance -> BuildSystemEntry? in
            guard let source = sources.first(where: { $0.pluginID == instance.pluginID }),
                  let declaration = source.buildSystems.first(where: { $0.id == instance.buildSystemID })
            else { return nil }
            let stored = Self.scopedOptions(
                declaration: declaration,
                workspace: storedOptions[instance.buildSystemID] ?? [:],
                instance: (instanceDefaults[instance.buildSystemID] ?? [:]).merging(instanceOptions[instance.buildSystemID]?[instance.root] ?? [:]) { _, root in root }
            )
            let target = BuildSystemTarget(manifest: source.manifest, buildSystemID: instance.buildSystemID)
            let earlier = previous[instance.id]
            // The instance ID is the build-system ID plus its root, so another
            // plugin can take the same ID over. Its model and dependencies are
            // not this plugin's data.
            let samePlugin = earlier?.instance.pluginID == instance.pluginID
            // A command or provider model only changes when the user loads it again.
            let kept = samePlugin && instance.model == nil && instance.loadsModelOnRequest
                ? earlier?.model
                : nil
            let model = instance.model ?? kept
            let sharedResolution = try? planner.resolveOptions(
                target, options: stored, modelValues: model?.optionValues
            )
            let input = Self.applyingEmptySelections(
                to: stored,
                optionIDs: emptyMultiSelectOptions[instance.buildSystemID]?[instance.root] ?? [],
                options: sharedResolution?.options ?? []
            )
            let resolution = input == stored ? sharedResolution : try? planner.resolveOptions(
                target, options: input, modelValues: model?.optionValues
            )
            let options = Self.effectiveOptionValues(resolution, stored: input)
            let sync = try? planner.syncFingerprint(
                target, workspaceURL: workspaceURL, root: instance.root,
                projects: model?.projects.map(\.path) ?? [], options: options
            )
            let stale = kept != nil && (earlier?.isReloadRequired == true || earlier?.sync?.fingerprint != sync?.fingerprint)
            let modelState: BuildModelState = if model != nil {
                .loaded
            } else if let error = instance.modelError {
                .failed(error.message)
            } else {
                .notLoaded
            }
            return BuildSystemEntry(
                instance: instance,
                declaration: declaration,
                source: source,
                model: model,
                modelState: modelState,
                options: resolution?.options ?? [],
                sync: sync,
                isReloadRequired: stale,
                dependencies: kept != nil ? earlier?.dependencies.filter { $0.value != .loading } ?? [:] : [:]
            )
        }
        return Detected(entries: entries, issues: issues)
    }
}

package struct BuildSystemServiceError: LocalizedError, Equatable {
    package let message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}

/// Output kept for Core's decoders, bounded as Core bounds it.
@MainActor
private final class OutputCollector {
    private let limit: Int
    private let keepsTail: Bool
    private(set) var text = ""
    private var byteCount = 0

    init(limit: Int, keepsTail: Bool = false) {
        self.limit = limit
        self.keepsTail = keepsTail
    }

    func append(_ chunk: String) {
        let size = chunk.utf8.count
        if keepsTail {
            text += chunk
            byteCount += size
            if byteCount > limit {
                text = String(text.suffix(limit / 2))
                byteCount = text.utf8.count
            }
        } else if byteCount + size <= limit {
            text += chunk
            byteCount += size
        }
    }
}
