import Combine
import Foundation
import LitheCoreContracts
import LitheModuleAPI

/// One operation's current provider identity. Options have a monotonic revision
/// in addition to their values so changing A -> B -> A invalidates old drafts.
package struct BuildNativeConfigurationContext: Equatable, Sendable {
    package let entryID: String
    package let source: BuildSystemPluginSource
    package let buildSystemID: String
    package let workspace: URL
    package let generation: Int
    package let configurationRevision: Int
    package let optionsRevision: Int
    package let settings: [String: ToolingJSONValue]
    package let plan: BuildPlanContext
    package var target: BuildSystemTarget { BuildSystemTarget(manifest: source.manifest, buildSystemID: buildSystemID) }
    package var provider: BuildProviderTarget {
        BuildProviderTarget(pluginID: source.pluginID, manifest: source.manifest,
            packageURL: source.packageURL, buildSystemID: buildSystemID, workspaceURL: workspace)
    }
    /// A successful native write invalidates model/file revisions itself. Its
    /// read-back still requires the same workspace, package, settings and options.
    fileprivate func sameIntent(as other: Self) -> Bool {
        entryID == other.entryID && source == other.source && buildSystemID == other.buildSystemID
            && workspace == other.workspace && generation == other.generation
            && optionsRevision == other.optionsRevision && settings == other.settings
            && plan.root == other.plan.root && plan.options == other.plan.options
    }
}

package struct BuildNativeConfigurationState: Equatable, Sendable {
    package enum Phase: Equatable, Sendable { case idle, loading, saving }
    package var phase: Phase = .idle
    package var snapshot: BuildNativeConfiguration?
    package var error: String?
    package var isStale = false
    package var requiresExplicitRead = false
    package var isBusy: Bool { phase != .idle }
}

/// Page-independent native configuration lifecycle, including guarded write and
/// upstream read-back. Original documents never enter this observable state.
@MainActor
package final class BuildNativeConfigurationCoordinator: ObservableObject {
    private let planner: any BuildSystemPlanning
    private let tools: any BuildToolResolving
    private let providers: (any BuildProviderRequesting)?
    private let files: (any BuildNativeConfigurationStoring)?
    private let context: @MainActor (String) throws -> BuildNativeConfigurationContext?
    private let didSave: @MainActor (String) -> Void
    package var onActivityChanged: (() -> Void)?
    @Published private var states: [String: BuildNativeConfigurationState] = [:]
    private var snapshots: [String: BuildNativeConfigurationContext] = [:]
    private struct Job {
        let id: UUID
        let context: BuildNativeConfigurationContext
        let task: Task<BuildNativeConfiguration, Error>
    }
    private var jobs: [String: Job] = [:]
    package var isBusy: Bool { !jobs.isEmpty }

    package init(planner: any BuildSystemPlanning, tools: any BuildToolResolving,
                 providers: (any BuildProviderRequesting)?, files: (any BuildNativeConfigurationStoring)?,
                 context: @escaping @MainActor (String) throws -> BuildNativeConfigurationContext?,
                 didSave: @escaping @MainActor (String) -> Void) {
        self.planner = planner; self.tools = tools; self.providers = providers; self.files = files
        self.context = context; self.didSave = didSave
    }

    package func state(_ entryID: String) -> BuildNativeConfigurationState {
        var value = states[entryID] ?? BuildNativeConfigurationState()
        if let saved = snapshots[entryID] { value.isStale = saved != (try? context(entryID)) }
        return value
    }

    package func read(_ entryID: String, allowProjectTool: Bool = false) async throws -> BuildNativeConfiguration {
        if let job = jobs[entryID] { return try await job.task.value }
        return try await start(entryID, saving: nil, allowProjectTool: allowProjectTool).value
    }

    package func save(_ entryID: String, snapshot: BuildNativeConfiguration,
                      edits: BuildNativeConfigurationEdits) async throws -> BuildNativeConfiguration {
        guard jobs[entryID] == nil else { throw NativeConfigurationOperationError.busy }
        guard let current = try context(entryID), snapshots[entryID] == current,
              states[entryID]?.snapshot == snapshot else { throw NativeConfigurationOperationError.stale }
        return try await start(entryID, saving: (snapshot, edits), allowProjectTool: true).value
    }

    package func stop() {
        let active = jobs.values
        jobs = [:]
        for job in active { job.task.cancel() }
        states = [:]; snapshots = [:]
        onActivityChanged?()
    }

    /// Retain a visible draft as stale while preventing its old owner from
    /// publishing a reply or writing after option/package changes.
    package func invalidate(buildSystemID: String? = nil) {
        for (entryID, job) in jobs where buildSystemID == nil || job.context.buildSystemID == buildSystemID {
            jobs[entryID] = nil
            job.task.cancel()
            var value = states[entryID] ?? BuildNativeConfigurationState()
            value.phase = .idle; value.isStale = true
            value.error = NativeConfigurationOperationError.stale.localizedDescription
            states[entryID] = value
        }
        onActivityChanged?()
    }

    private func start(_ entryID: String, saving: (BuildNativeConfiguration, BuildNativeConfigurationEdits)?, allowProjectTool: Bool) throws -> Task<BuildNativeConfiguration, Error> {
        guard let current = try context(entryID), providers != nil else { throw NativeConfigurationOperationError.unavailable }
        let id = UUID()
        var state = states[entryID] ?? BuildNativeConfigurationState()
        state.phase = saving == nil ? .loading : .saving; state.error = nil
        state.requiresExplicitRead = false
        states[entryID] = state
        let task = Task { @MainActor [weak self] () throws -> BuildNativeConfiguration in
            guard let self else { throw CancellationError() }
            defer {
                if self.jobs[entryID]?.id == id {
                    self.jobs[entryID] = nil
                    var value = self.states[entryID] ?? BuildNativeConfigurationState()
                    value.phase = .idle; self.states[entryID] = value
                    self.onActivityChanged?()
                }
            }
            do {
                var readContext = current
                var published: BuildNativeConfigurationPreparedWrite?
                if let (snapshot, edits) = saving {
                    guard let files = self.files else { throw NativeConfigurationOperationError.unavailable }
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try files.prepare(target: current.target, snapshot: snapshot, edits: edits)
                    }.value
                    try self.check(entryID, owner: id, expected: current)
                    guard let prepared else { return snapshot }
                    // No actor suspension between the ownership check and CAS.
                    try files.commit(prepared)
                    published = prepared
                    self.didSave(entryID)
                    guard let after = try self.context(entryID), current.sameIntent(as: after) else {
                        throw NativeConfigurationOperationError.stale
                    }
                    readContext = after
                }
                let result = try await self.probe(readContext, allowProjectTool: allowProjectTool)
                try self.check(entryID, owner: id, expected: readContext, readBack: published != nil)
                if let published, let (_, edits) = saving {
                    guard let source = result.sources.first(where: { $0.id == edits.sourceID }),
                          URL(string: source.uri)?.standardizedFileURL.resolvingSymlinksInPath() == published.url,
                          source.revision == published.revision else { throw NativeConfigurationOperationError.readBack }
                }
                self.snapshots[entryID] = try self.context(entryID)
                self.states[entryID] = BuildNativeConfigurationState(snapshot: result)
                return result
            } catch {
                if self.jobs[entryID]?.id == id {
                    var value = self.states[entryID] ?? BuildNativeConfigurationState()
                    value.error = error.localizedDescription
                    value.requiresExplicitRead = (error as? NativeConfigurationOperationError) == .explicitRead
                    self.states[entryID] = value
                }
                throw error
            }
        }
        jobs[entryID] = Job(id: id, context: current, task: task)
        onActivityChanged?()
        return task
    }

    private func check(_ entryID: String, owner: UUID, expected: BuildNativeConfigurationContext, readBack: Bool = false) throws {
        try Task.checkCancellation()
        guard jobs[entryID]?.id == owner, let current = try context(entryID),
              readBack ? expected.sameIntent(as: current) : expected == current else {
            throw NativeConfigurationOperationError.stale
        }
    }

    private func probe(_ context: BuildNativeConfigurationContext, allowProjectTool: Bool) async throws -> BuildNativeConfiguration {
        guard let providers else { throw NativeConfigurationOperationError.unavailable }
        let planner = planner
        let invocation = try planner.invocationPlan(context.target, root: context.plan.root, settings: context.settings)
        let tool: ResolvedBuildTool?
        do {
            if invocation.executables.isEmpty { tool = nil }
            else {
                let selected = try await tools.resolve(invocation,
                    displayName: context.buildSystemID, workspaceURL: context.workspace) { runtime, output in
                        try planner.checkToolVersion(context.target, runtime: runtime, output: output)
                    }
                // Opening a settings page cannot run a repository wrapper or
                // trigger its cold download. Explicit Read/Save owns that work.
                if selected.executesProjectCode && !allowProjectTool { throw NativeConfigurationOperationError.explicitRead }
                tool = selected
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if error as? NativeConfigurationOperationError == .explicitRead { throw error }
            if invocation.hasExplicitExecutableSelection || (error as? BuildToolResolutionError)?.terminal == true { throw error }
            if !allowProjectTool { throw NativeConfigurationOperationError.explicitRead }
            tool = nil
        }
        try Task.checkCancellation()
        let request = try planner.configurationPlan(context.target, context: context.plan,
            hints: BuildProviderHints(reason: .refresh, toolExecutable: tool?.executableURL, toolEnvironment: tool?.providerEnvironment ?? [:]))
        let result = try await providers.send(request, to: context.provider, timeout: .seconds(60))
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try planner.decodeConfiguration(context.target, result: result)
        }.value
    }
}

private enum NativeConfigurationOperationError: LocalizedError, Equatable {
    case unavailable, stale, busy, readBack, explicitRead
    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.string("Native configuration is unavailable.")
        case .stale: L10n.string("Native configuration changed. Reload before saving; your draft has been kept.")
        case .busy: L10n.string("Native configuration is busy. Wait for the current operation to finish.")
        case .readBack: L10n.string("Native configuration was saved, but its current effective values could not be verified. Reload before editing again.")
        case .explicitRead: L10n.string("Reading configuration with this project tool requires an explicit action.")
        }
    }
}
