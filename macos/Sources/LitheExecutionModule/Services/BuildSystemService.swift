import Combine
import Foundation
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

package enum BuildRunState: Equatable, Sendable {
    case idle
    case running
    case succeeded
    case failed(String)
    case cancelled
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
    @Published package private(set) var diagnostics: [BuildDiagnostic] = []
    @Published package private(set) var testResults: BuildTestResults?
    package private(set) var workspaceURL: URL?

    private let planner: any BuildSystemPlanning
    private let tools: any BuildToolResolving
    private let optionsStore: any BuildOptionsStoring
    private let stateLocator: any BuildSystemStateLocating
    private let runner: any BuildCommandRunning
    private let sources: @MainActor () -> [BuildSystemPluginSource]

    /// Bumped whenever the workspace changes, so late results are dropped.
    private var generation = 0
    /// Bumped whenever a load changes one entry's model or dependencies.
    /// Detection captures these numbers with its snapshot and does not
    /// overwrite state that changed while it ran. Model and dependency
    /// revisions are separate: a dependency result must not replace a model
    /// the detection just read.
    private var modelRevisions: [String: Int] = [:]
    private var dependencyRevisions: [String: Int] = [:]
    /// Bumped when a watched workspace file changes, so a load that started
    /// before the change can tell its result is based on older files.
    private var fileRevision = 0
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
        sources: @escaping @MainActor () -> [BuildSystemPluginSource]
    ) {
        self.planner = planner
        self.tools = tools
        self.optionsStore = optionsStore
        self.stateLocator = stateLocator
        self.runner = runner
        self.sources = sources
    }

    package var isRunning: Bool { runState == .running }
    package var isLoadingModel: Bool { !modelTasks.isEmpty }
    package var isLoadingDependencies: Bool { !dependencyTasks.isEmpty }
    /// True when an enabled plugin declares a build system, detected or not.
    package var hasBuildSystemPlugins: Bool { !sources().isEmpty }

    package func entry(_ id: String) -> BuildSystemEntry? {
        entries.first { $0.id == id }
    }

    // MARK: Workspace

    /// Forgets the previous workspace and detects the new one.
    package func reset(workspaceURL: URL?) {
        stop()
        generation += 1
        detectionTask?.cancel(); detectionTask = nil
        redetectTask?.cancel(); redetectTask = nil
        self.workspaceURL = workspaceURL?.standardizedFileURL
        entries = []
        modelRevisions = [:]
        dependencyRevisions = [:]
        fileRevision = 0
        issues = []
        isDetecting = false
        runState = .idle
        runningTitle = nil
        clearOutput()
        detect()
    }

    /// Detects the instances again. Static and host-integration models are
    /// read again with them; a loaded command model is kept and marked
    /// stale when the files it depends on changed.
    package func detect() {
        guard let workspaceURL else { return }
        detectionTask?.cancel()
        let sources = sources()
        guard !sources.isEmpty else {
            entries = []
            issues = []
            isDetecting = false
            return
        }
        isDetecting = true
        let storedOptions = Dictionary(
            sources.flatMap(\.buildSystems).map {
                ($0.id, optionsStore.options(workspaceURL: workspaceURL, buildSystemID: $0.id))
            },
            uniquingKeysWith: { first, _ in first }
        )
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
                        previous: previous
                    )
                }
            }.value
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.isDetecting = false
            switch result {
            case .success(let detected):
                let current = Dictionary(uniqueKeysWithValues: self.entries.map { ($0.id, $0) })
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
                    return merged
                }
                self.issues = detected.issues
                self.persistDroppedOptions()
            case .failure(let error):
                self.entries = []
                self.issues = [error.localizedDescription]
            }
        }
    }

    /// Ends what a now disabled plugin started and detects again with the
    /// plugins enabled now, so its instances leave the tool window.
    package func pluginsChanged() {
        let enabled = Set(sources().map(\.pluginID))
        let removed = Set(entries.filter { !enabled.contains($0.instance.pluginID) }.map(\.id))
        if let runEntryID, removed.contains(runEntryID) { stopRun() }
        for key in Array(modelTasks.keys) where removed.contains(key) {
            modelTasks.removeValue(forKey: key)?.cancel()
        }
        for key in Array(dependencyTasks.keys) where removed.contains(Self.entryID(ofDependencyTask: key)) {
            dependencyTasks.removeValue(forKey: key)?.cancel()
        }
        detect()
    }

    /// Detects again shortly after a file the models depend on changed.
    /// Several saves in a row cost one detection.
    package func workspaceFilesChanged(_ urls: [URL]) {
        guard let workspaceURL, !entries.isEmpty else { return }
        // A load can read a subproject file before the model lists it, so any
        // reported change invalidates a model load that is in flight.
        fileRevision += 1
        let root = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        let changed = Set(urls.compactMap { url -> String? in
            let path = url.standardizedFileURL.path
            return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
        })
        let affected = entries.contains { entry in
            entry.sync?.watch.contains(where: changed.contains) == true
        }
        guard affected else { return }
        redetectTask?.cancel()
        redetectTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.detect()
        }
    }

    // MARK: Model

    /// Runs the model command of a command-sourced instance. Other sources
    /// are read again by detection.
    package func loadModel(_ entryID: String) {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        switch entry.instance.modelSource {
        case .static?, .hostIntegration?:
            detect()
            return
        case .provider?:
            update(entryID) {
                $0.modelState = .failed(Self.providerUnsupportedMessage)
            }
            return
        case nil:
            return
        case .command?:
            break
        }
        modelTasks[entryID]?.cancel()
        update(entryID) { $0.modelState = .loading }
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
                owner: .modelLoad(generation: generation, entryID: entryID, id: id)
            )
            guard self.generation == generation, self.modelTasks[entryID]?.id == id,
                  !Task.isCancelled else { return }
            self.modelTasks[entryID] = nil
            switch result {
            case .success(let loaded):
                let configChanged: Bool = {
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
                self.refreshOptions(buildSystemID: entry.instance.buildSystemID)
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
        owner: CommandOwner
    ) async -> Result<LoadedModel, Error> {
        do {
            let context = try planContext(entry, workspaceURL: workspaceURL)
            let outputFile = try context.workspaceStateDirectory.map { try stateLocator.allocateOutputFile(in: $0) }
            defer { if let outputFile { stateLocator.removeOutputFile(outputFile) } }
            let plan = try planner.modelPlan(entry.target, context: context, outputFile: outputFile)
            guard case .process(let process) = plan else { throw BuildSystemServiceError(Self.providerUnsupportedMessage) }
            let title = String(localized: "Loading \(entry.instance.displayName) model")
            let output = try await runCapturedCommand(
                process,
                entry: entry,
                workspaceURL: workspaceURL,
                outputFile: outputFile,
                title: title,
                timeout: Self.modelTimeout,
                owner: owner
            )
            let planner = planner
            let target = entry.target
            let root = entry.instance.root
            return .success(try await Task.detached(priority: .userInitiated) {
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
            }.value)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Tasks and tests

    /// Runs a declared task, or a model task through its template.
    package func runTask(_ entryID: String, request: BuildTaskRequest, title: String) {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        startRun(entryID, title: title) { service, run in
            let context = try service.planContext(entry, workspaceURL: workspaceURL)
            let plan = try service.planner.taskPlan(entry.target, context: context, request: request)
            let collected = try await service.runStreamedCommand(
                plan, entry: entry, workspaceURL: workspaceURL, owner: .run(run)
            )
            let diagnostics = await service.decodeDiagnostics(entry, workspaceURL: workspaceURL, output: collected.text)
            // The decode runs after the command; a stop, replacement, or
            // workspace switch in between must not publish into the new state.
            guard service.isCurrent(run) else { throw CancellationError() }
            service.diagnostics = diagnostics
            return collected.exitCode
        }
    }

    package func runTests(_ entryID: String, request: BuildTestRequest, title: String) {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        startRun(entryID, title: title) { service, run in
            let context = try service.planContext(entry, workspaceURL: workspaceURL)
            let plan = try service.planner.testPlan(entry.target, context: context, request: request)
            if plan.results != nil, request.project == nil,
               entry.instance.modelSource != nil,
               entry.model == nil || entry.isReloadRequired {
                // Report globs are relative to each project; without a current
                // model a new subproject's reports are invisible and a failing
                // run would decode as success. A plugin without a model has no
                // projects to discover, so its own reports stay readable.
                throw BuildSystemServiceError(String(
                    localized: "Load or reload the project model before running all tests, so subproject reports are collected."
                ))
            }
            let started = Date()
            let collected = try await service.runStreamedCommand(
                plan.process, entry: entry, workspaceURL: workspaceURL, owner: .run(run)
            )
            let diagnostics = await service.decodeDiagnostics(entry, workspaceURL: workspaceURL, output: collected.text)
            guard service.isCurrent(run) else { throw CancellationError() }
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
                    guard service.isCurrent(run) else { throw CancellationError() }
                    service.testResults = results
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard service.isCurrent(run) else { throw CancellationError() }
                    service.appendOutput("\n" + error.localizedDescription + "\n")
                }
            }
            return collected.exitCode
        }
    }

    /// Ends the task or test run. Model and dependency commands keep running.
    package func stopRun() {
        guard runTask != nil else { return }
        runTask?.cancel()
        runTask = nil
        runID = nil
        runEntryID = nil
        if runState == .running {
            runState = .cancelled
        }
    }

    /// Ends every process this service started.
    package func stop() {
        stopRun()
        for task in modelTasks.values { task.cancel() }
        for task in dependencyTasks.values { task.cancel() }
        modelTasks = [:]
        dependencyTasks = [:]
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
        diagnostics = []
        testResults = nil
    }

    private func startRun(
        _ entryID: String,
        title: String,
        _ work: @escaping @MainActor (BuildSystemService, RunIdentity) async throws -> Int32?
    ) {
        stopRun()
        clearOutput()
        let id = UUID()
        let run = RunIdentity(id: id, generation: generation)
        runID = id
        runEntryID = entryID
        runState = .running
        runningTitle = title
        runTask = Task { [weak self] in
            guard let self else { return }
            let state: BuildRunState
            do {
                if let exitCode = try await work(self, run) {
                    state = exitCode == 0
                        ? .succeeded
                        : .failed(String(localized: "The build tool exited with code \(Int(exitCode))."))
                } else {
                    state = .failed(String(localized: "The build tool timed out."))
                }
            } catch is CancellationError {
                state = .cancelled
            } catch {
                if self.runID == id {
                    self.appendOutput(error.localizedDescription + "\n")
                }
                state = .failed(error.localizedDescription)
            }
            guard self.runID == id else { return }
            self.runState = state
            self.runTask = nil
            self.runID = nil
            self.runEntryID = nil
        }
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
    package func loadDependencies(_ entryID: String, project: BuildModel.Project?) {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        let key = project?.path ?? entry.instance.root
        let taskKey = entryID + Self.dependencyTaskSeparator + key
        dependencyTasks[taskKey]?.cancel()
        update(entryID) { $0.dependencies[key] = .loading }
        let generation = generation
        let id = UUID()
        let optionFingerprint = optionFingerprint(entry, workspaceURL: workspaceURL)
        let task = Task { [weak self] in
            guard let self else { return }
            let result = await self.performDependencyLoad(
                entry,
                project: project,
                workspaceURL: workspaceURL,
                owner: .dependencyLoad(generation: generation, taskKey: taskKey, id: id)
            )
            guard self.generation == generation, self.dependencyTasks[taskKey]?.id == id,
                  !Task.isCancelled else { return }
            self.dependencyTasks[taskKey] = nil
            let current = self.entry(entryID) ?? entry
            let configChanged = self.optionFingerprint(current, workspaceURL: workspaceURL)
                != optionFingerprint
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
        owner: CommandOwner
    ) async -> Result<BuildDependencyTree, Error> {
        do {
            let context = try planContext(entry, workspaceURL: workspaceURL)
            let outputFile = try context.workspaceStateDirectory.map { try stateLocator.allocateOutputFile(in: $0) }
            defer { if let outputFile { stateLocator.removeOutputFile(outputFile) } }
            let plan = try planner.dependencyPlan(
                entry.target,
                context: context,
                project: project.map(BuildSelection.init(project:)),
                outputFile: outputFile
            )
            guard case .process(let process) = plan else { throw BuildSystemServiceError(Self.providerUnsupportedMessage) }
            let name = project?.displayName ?? project?.name ?? entry.instance.displayName
            let output = try await runCapturedCommand(
                process,
                entry: entry,
                workspaceURL: workspaceURL,
                outputFile: outputFile,
                title: String(localized: "Loading dependencies of \(name)"),
                timeout: Self.modelTimeout,
                owner: owner
            )
            let planner = planner
            let target = entry.target
            let root = entry.instance.root
            return .success(try await Task.detached(priority: .userInitiated) {
                try planner.decodeDependencies(
                    target, workspaceURL: workspaceURL, root: root, project: project?.path, output: output
                )
            }.value)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Options

    /// Stores one option value, or removes it with nil, for every instance
    /// of the build system in this workspace.
    package func setOption(_ entryID: String, optionID: String, value: ToolingJSONValue?) {
        guard let workspaceURL, let entry = entry(entryID) else { return }
        let buildSystemID = entry.instance.buildSystemID
        var stored = optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        stored[optionID] = value
        optionsStore.setOptions(stored, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        refreshOptions(buildSystemID: buildSystemID)
        // The options take part in the sync fingerprint, so a changed value
        // marks a loaded command model stale.
        detect()
    }

    private func refreshOptions(buildSystemID: String) {
        guard let workspaceURL else { return }
        let stored = optionsStore.options(workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        var resolutions: [BuildOptionsResolution] = []
        for index in entries.indices where entries[index].instance.buildSystemID == buildSystemID {
            guard let resolution = try? planner.resolveOptions(
                entries[index].target,
                options: stored,
                modelValues: entries[index].model?.optionValues
            ) else { continue }
            entries[index].options = resolution.options
            resolutions.append(resolution)
        }
        // Options are stored per workspace and build system, but a model
        // value is valid for one instance. Keep a value as long as any
        // instance still accepts it; each plan filters it against its own
        // model, so one instance cannot delete another's selection.
        let merged = Self.mergedOptionValues(stored: stored, resolutions: resolutions)
        if merged != stored {
            optionsStore.setOptions(merged, workspaceURL: workspaceURL, buildSystemID: buildSystemID)
        }
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
    private func persistDroppedOptions() {
        for buildSystemID in Set(entries.map(\.instance.buildSystemID)) {
            refreshOptions(buildSystemID: buildSystemID)
        }
    }

    // MARK: Commands

    private func optionFingerprint(_ entry: BuildSystemEntry, workspaceURL: URL) -> String? {
        let stored = optionsStore.options(
            workspaceURL: workspaceURL, buildSystemID: entry.instance.buildSystemID
        )
        return (try? planner.resolveOptions(
            entry.target, options: stored, modelValues: entry.model?.optionValues
        ))?.fingerprint
    }

    private func planContext(_ entry: BuildSystemEntry, workspaceURL: URL) throws -> BuildPlanContext {
        let stored = optionsStore.options(
            workspaceURL: workspaceURL, buildSystemID: entry.instance.buildSystemID
        )
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
            )
        )
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
        let invocation = try planner.invocationPlan(target, root: entry.instance.root)
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
        if canAppend(owner) { appendOutput(Self.commandLine(request)) }
        let collector = OutputCollector(limit: Self.decodedOutputLimit)
        let result = try await run(request, owner: owner) { [weak self] chunk in
            collector.append(chunk)
            self?.appendOutput(chunk)
        }
        let exitCode: Int32? = switch result.termination {
        case .exited(let code): code
        case .timedOut: nil
        }
        return CollectedOutput(text: collector.text, exitCode: exitCode)
    }

    /// Runs a model or dependency command and returns what Core decodes.
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
        if canAppend(owner) {
            appendOutput("\n▶ " + title + "\n" + Self.commandLine(request))
        }
        let tail = OutputCollector(limit: 64 * 1024, keepsTail: true)
        let result = try await run(request, owner: owner) { [weak self] chunk in
            tail.append(chunk)
            self?.appendOutput(chunk)
        }
        switch result.termination {
        case .timedOut:
            throw BuildSystemServiceError(String(localized: "\(title) timed out."))
        case .exited(let code) where code != 0:
            let detail = tail.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = String(localized: "The build tool exited with code \(Int(code)).")
            throw BuildSystemServiceError(detail.isEmpty ? summary : summary + "\n" + Self.lastLines(detail))
        case .exited:
            break
        }
        if capturesStandardOutput {
            guard let text = result.standardOutput else {
                throw BuildSystemServiceError(String(localized: "The build tool output is too large or not UTF-8."))
            }
            return .stdout(text)
        }
        guard let outputFile else {
            throw BuildSystemServiceError(String(localized: "The build tool output is too large or not UTF-8."))
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

    private func appendOutput(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        output += chunk
        outputByteCount += chunk.utf8.count
        if outputByteCount > Self.visibleOutputLimit {
            output = String(output.suffix(Self.visibleOutputLimit / 2))
            outputByteCount = output.utf8.count
        }
    }

    private func refreshActivity() {
        let active = isRunning || isLoadingModel || isLoadingDependencies
        if hasActiveWork != active { hasActiveWork = active }
    }

    private func update(_ entryID: String, _ change: (inout BuildSystemEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        change(&entries[index])
    }

    private func noteModelChanged(_ entryID: String) {
        modelRevisions[entryID, default: 0] += 1
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
        String(localized: "This build system answers through a provider process, which Lithe for macOS does not run yet.")
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
        previous: [String: BuildSystemEntry]
    ) throws -> Detected {
        let detection = try planner.detect(workspaceURL: workspaceURL, sources: sources, options: storedOptions)
        var issues = detection.rejected.map { rejected in
            let pluginID = sources.indices.contains(rejected.index) ? sources[rejected.index].pluginID : "?"
            return "\(pluginID): \(rejected.error.message)"
        }
        issues += detection.shadowed.map {
            String(localized: "\($0.buildSystemID) of \($0.pluginID) is handled by \($0.by).")
        }
        let entries = detection.instances.compactMap { instance -> BuildSystemEntry? in
            guard let source = sources.first(where: { $0.pluginID == instance.pluginID }),
                  let declaration = source.buildSystems.first(where: { $0.id == instance.buildSystemID })
            else { return nil }
            let stored = storedOptions[instance.buildSystemID] ?? [:]
            let target = BuildSystemTarget(manifest: source.manifest, buildSystemID: instance.buildSystemID)
            let earlier = previous[instance.id]
            // The instance ID is the build-system ID plus its root, so another
            // plugin can take the same ID over. Its model and dependencies are
            // not this plugin's data.
            let samePlugin = earlier?.instance.pluginID == instance.pluginID
            // A command model only changes when the user loads it again.
            let kept = samePlugin && instance.model == nil && instance.modelSource == .command
                ? earlier?.model
                : nil
            let model = instance.model ?? kept
            let resolution = try? planner.resolveOptions(
                target, options: stored, modelValues: model?.optionValues
            )
            let options = Self.effectiveOptionValues(resolution, stored: stored)
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
