import Combine
import Foundation
import LitheModuleAPI
import LitheCoreContracts

private enum MavenReloadError: LocalizedError {
    case projectUnavailable
    var errorDescription: String? {
        L10n.string("The Maven project could not be reloaded. The previous model is still available.")
    }
}

private struct MavenProjectInventory: Equatable {
    let rootURL: URL
    let descriptorPaths: [String]

    init(rootURL: URL, files: [URL]) {
        let root = rootURL.standardizedFileURL
        let rootComponents = root.pathComponents
        self.rootURL = root
        descriptorPaths = Set(files.compactMap { fileURL -> String? in
            let file = fileURL.standardizedFileURL
            guard file.lastPathComponent.lowercased() == "pom.xml",
                  file.pathComponents.starts(with: rootComponents) else { return nil }
            return file.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
        }).sorted()
    }
}

@MainActor
package final class MavenService: ObservableObject {
    @Published package private(set) var project: MavenProject?
    @Published package private(set) var projectState: MavenProjectLoadState = .idle
    @Published package private(set) var selectedProfiles: Set<String> = []
    @Published package private(set) var customProfiles: [String] = []
    @Published package private(set) var skipTests = false
    @Published package private(set) var settingsPath: String?
    @Published package private(set) var localRepositoryPath: String?
    @Published package private(set) var mavenExecutablePath: String?
    @Published package private(set) var javaHomePath: String?
    @Published package private(set) var configurationSaveError: String?
    /// Why the running Java language session did not take the latest Maven
    /// configuration. The reload action restarts that session.
    @Published package private(set) var javaConfigurationError: String?
    @Published package private(set) var isReloadRequired = false
    @Published package private(set) var isProjectReloadRequired = false
    @Published package private(set) var isReloading = false
    @Published package private(set) var reloadError: String?
    private var reloadRevision = 0
    private var reloadTask: Task<Void, Never>?
    package var onProjectReloaded: (@MainActor (URL, MavenProject) -> Void)?
    /// Hands the current configuration to the workspace's running Java language
    /// session. Returns whether a running session took it and throws when one
    /// could not. JDT LS re-resolves in place, so no reload is needed (#970).
    package var applyConfigurationToJava: (@MainActor (URL) throws -> Bool)?

    package var isLoadingProject: Bool {
        if case .loading = projectState { return true }
        return false
    }

    package var availableProfiles: [MavenProfile] {
        var seen = Set<String>()
        let discovered = project?.profiles.filter { seen.insert($0.id).inserted } ?? []
        let custom = customProfiles.compactMap { id -> MavenProfile? in
            guard seen.insert(id).inserted else { return nil }
            return MavenProfile(id: id, isActiveByDefault: false)
        }
        return discovered + custom
    }

    package var launchContext: MavenLaunchContext? {
        guard let reactorPath else { return nil }
        return MavenLaunchContext(
            reactorPath: reactorPath,
            profiles: selectedProfiles.sorted(),
            settingsPath: settingsPath,
            localRepositoryPath: localRepositoryPath,
            skipTests: skipTests,
            mavenExecutablePath: resolvedMavenExecutablePath,
            javaHomePath: javaHomePath
        )
    }

    /// Maven this workspace runs, falling back to the wrapper or a discovered
    /// installation when Maven Settings leaves the path empty.
    ///
    /// Project import reads the local repository and mirrors from the
    /// installation's `conf/settings.xml`. Passing an empty path would leave the
    /// language server on its embedded defaults while builds keep using the
    /// resolved installation, so the same project would resolve against two
    /// different local repositories.
    private var resolvedMavenExecutablePath: String? {
        if let mavenExecutablePath { return mavenExecutablePath }
        guard let project else { return nil }
        return runtimeService.mavenExecutable(for: project, overridePath: nil)?.path
    }

    private let mavenOperations: any MavenProjectOperations
    private let runtimeService: any MavenRuntimePort
    private let configurationWriter: MavenConfigurationWriter
    private var workspaceURL: URL?
    private var reactorPath: String?
    private var projectLoadID = UUID()
    private var acceptedProjectInventory: MavenProjectInventory?
    private var projectLoadInventory: MavenProjectInventory?
    private var projectLoadTask: Task<Void, Never>?
    private var configurationRevision = 0
    private var configurationSaveTask: Task<String?, Never>?
    private var configurationFingerprint: String?
    private var fingerprintRevision = 0

    package init(
        runtimeService: any MavenRuntimePort,
        mavenOperations: any MavenProjectOperations,
        configurationStore: (any MavenConfigurationStoring)? = nil
    ) {
        self.runtimeService = runtimeService
        self.mavenOperations = mavenOperations
        configurationWriter = MavenConfigurationWriter(store: configurationStore)
    }

    package func loadProject(at workspaceURL: URL, files: [URL]) async {
        let inventory = MavenProjectInventory(rootURL: workspaceURL, files: files)
        if let currentRoot = self.workspaceURL ?? projectLoadInventory?.rootURL,
           currentRoot != inventory.rootURL {
            reset()
        }

        // A ready model is the cache for its accepted POM inventory. Snapshot
        // refreshes must not rescan unchanged descriptors or accept changed
        // descriptors before the explicit Reload transaction synchronizes Java.
        if self.workspaceURL == inventory.rootURL, project != nil {
            if acceptedProjectInventory != inventory, !isProjectReloadRequired {
                reloadRevision += 1
                isProjectReloadRequired = true
                isReloadRequired = true
            }
            return
        }

        if projectLoadInventory == inventory, let projectLoadTask {
            await projectLoadTask.value
            return
        }
        if projectLoadTask != nil {
            projectLoadID = UUID()
            projectLoadTask?.cancel()
            projectLoadTask = nil
            projectLoadInventory = nil
        }

        let loadID = UUID()
        projectLoadID = loadID
        projectLoadInventory = inventory
        projectState = .loading
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.projectLoadID == loadID {
                    self.projectLoadTask = nil
                    self.projectLoadInventory = nil
                    if self.projectState == .loading {
                        self.projectState = self.project == nil ? .idle : .ready
                    }
                }
            }
            // Before a model is accepted, a POM event invalidates the scan rather
            // than asking the user to reload a model that does not exist yet.
            // All matching inventory callers keep awaiting this owned task.
            while !Task.isCancelled, self.projectLoadID == loadID {
                let revision = self.reloadRevision
                await self.performProjectLoad(
                    inventory: inventory,
                    files: files,
                    loadID: loadID,
                    revision: revision
                )
                guard self.project == nil, self.reloadRevision != revision else { return }
            }
        }
        projectLoadTask = task
        await task.value
    }

    private func performProjectLoad(
        inventory: MavenProjectInventory,
        files: [URL],
        loadID: UUID,
        revision: Int
    ) async {
        let rootURL = inventory.rootURL
        let mavenOperations = mavenOperations
        let configurationWriter = configurationWriter
        let result = await Task.detached(priority: .utility) {
            do {
                let project = try mavenOperations.scanMavenProject(at: rootURL, files: files)
                let reactorPath = project.map { Self.relativePath(from: rootURL, to: $0.rootURL) }
                let stored: MavenStoredConfiguration?
                if let reactorPath {
                    stored = try await configurationWriter.load(
                        workspaceURL: rootURL,
                        reactorPath: reactorPath
                    )
                } else {
                    stored = nil
                }
                return MavenProjectLoadResult(
                    project: project,
                    reactorPath: reactorPath,
                    stored: stored,
                    errorMessage: nil
                )
            } catch {
                return MavenProjectLoadResult(
                    project: nil,
                    reactorPath: nil,
                    stored: nil,
                    errorMessage: error.localizedDescription
                )
            }
        }.value
        guard !Task.isCancelled, projectLoadID == loadID, reloadRevision == revision else { return }

        guard let errorMessage = result.errorMessage else {
            self.workspaceURL = rootURL
            reactorPath = result.reactorPath
            project = result.project
            acceptedProjectInventory = result.project == nil ? nil : inventory
            applyStoredConfiguration(result.stored, project: result.project)
            if let context = launchContext {
                let fingerprint = await Task.detached(priority: .utility) {
                    try? mavenOperations.mavenLaunchPlan(
                        at: rootURL,
                        context: context,
                        module: nil,
                        goals: [MavenLifecyclePhase.validate.rawValue]
                    ).configurationFingerprint
                }.value
                guard !Task.isCancelled, projectLoadID == loadID, reloadRevision == revision else { return }
                configurationFingerprint = fingerprint
            } else {
                configurationFingerprint = nil
            }
            projectState = .ready
            configurationSaveError = nil
            isReloadRequired = isProjectReloadRequired
            return
        }
        project = nil
        self.workspaceURL = nil
        reactorPath = nil
        acceptedProjectInventory = nil
        projectState = .failed(errorMessage)
    }

    package func setSelectedProfiles(_ profiles: Set<String>) {
        let knownProfiles = Set(availableProfiles.map(\.id))
        let normalized = Set(profiles.filter { knownProfiles.contains($0) })
        guard normalized != selectedProfiles else { return }
        selectedProfiles = normalized
        configurationDidChange()
    }

    @discardableResult
    package func addCustomProfile(_ value: String) -> Bool {
        let profile = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidProfile(profile) else { return false }
        if !customProfiles.contains(profile), project?.profiles.contains(where: { $0.id == profile }) != true {
            customProfiles.append(profile)
            customProfiles.sort()
        }
        selectedProfiles.insert(profile)
        configurationDidChange()
        return true
    }

    package func restoreDefaultProfiles() {
        let defaults = Set(project?.profiles.filter(\.isActiveByDefault).map(\.id) ?? [])
        guard selectedProfiles != defaults else { return }
        selectedProfiles = defaults
        configurationDidChange()
    }

    package func setSkipTests(_ enabled: Bool) {
        guard skipTests != enabled else { return }
        skipTests = enabled
        configurationDidChange()
    }

    package func updateLocalConfiguration(
        settingsPath: String?,
        localRepositoryPath: String?,
        mavenExecutablePath: String?,
        javaHomePath: String?
    ) {
        let settings = normalizedLocalPath(settingsPath)
        let localRepository = normalizedLocalPath(localRepositoryPath)
        let executable = normalizedLocalPath(mavenExecutablePath)
        let javaHome = normalizedLocalPath(javaHomePath)
        guard settings != self.settingsPath
                || localRepository != self.localRepositoryPath
                || executable != self.mavenExecutablePath
                || javaHome != self.javaHomePath else { return }
        self.settingsPath = settings
        self.localRepositoryPath = localRepository
        self.mavenExecutablePath = executable
        self.javaHomePath = javaHome
        configurationDidChange()
    }

    package func acknowledgeReload() {
        guard !isProjectReloadRequired else { return }
        isReloadRequired = false
        javaConfigurationError = nil
        refreshConfigurationFingerprint(establishBaseline: true)
    }

    /// Marks only descriptors owned by this workspace; deletion is a change too.
    package func markPomChanged(_ fileURL: URL) {
        guard let workspaceURL = workspaceURL ?? projectLoadInventory?.rootURL else { return }
        let file = fileURL.standardizedFileURL
        guard file.lastPathComponent.lowercased() == "pom.xml",
              file.path.hasPrefix(workspaceURL.path + "/") else { return }
        reloadRevision += 1
        guard project != nil else { return }
        isProjectReloadRequired = true
        isReloadRequired = true
    }

    /// Keeps the accepted model visible until both scan and Java import succeed.
    /// One owned task coalesces repeated clicks and is cancelled on workspace reset.
    package func reloadProject(
        files: [URL],
        rescan: Bool,
        synchronizeJava: @escaping @MainActor () async throws -> Void
    ) async {
        if let reloadTask { await reloadTask.value; return }
        guard let root = workspaceURL, let context = launchContext else { return }
        // Invalidate inventory scans that started before this explicit transaction.
        reloadRevision += 1
        let revision = reloadRevision
        let loadID = projectLoadID
        let previousProject = project
        let operations = mavenOperations
        let inventory = MavenProjectInventory(rootURL: root, files: files)
        isReloading = true
        reloadError = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.projectLoadID == loadID {
                    self.isReloading = false
                    self.reloadTask = nil
                }
            }
            do {
                let candidate = try await Task.detached(priority: .utility) {
                    let project = rescan
                        ? try operations.scanMavenProject(at: root, files: files)
                        : previousProject
                    guard let project, project.rootURL.standardizedFileURL == previousProject?.rootURL.standardizedFileURL else {
                        throw MavenReloadError.projectUnavailable
                    }
                    let fingerprint = try operations.mavenLaunchPlan(
                        at: root, context: context, module: nil, goals: ["validate"]
                    ).configurationFingerprint
                    return (project, fingerprint)
                }.value
                try Task.checkCancellation()
                guard self.projectLoadID == loadID, self.reloadRevision == revision else { return }
                try await synchronizeJava()
                try Task.checkCancellation()
                guard self.projectLoadID == loadID, self.reloadRevision == revision else { return }
                self.project = candidate.0
                self.acceptedProjectInventory = inventory
                self.configurationFingerprint = candidate.1
                self.fingerprintRevision += 1
                self.isProjectReloadRequired = false
                self.isReloadRequired = false
                self.javaConfigurationError = nil
                self.projectState = .ready
                self.onProjectReloaded?(root, candidate.0)
            } catch {
                guard self.projectLoadID == loadID, self.reloadRevision == revision else { return }
                self.reloadError = error is CancellationError
                    ? L10n.string("Maven reload was cancelled or timed out.")
                    : error.localizedDescription
                self.isReloadRequired = true
            }
        }
        reloadTask = task
        // Java import owns its progress-aware and absolute deadlines in Core.
        // An outer wall-clock timeout would abort a healthy import downloading
        // dependencies. Explicit cancellation still resumes the readiness waiter
        // and releases only the Java session owned by this reload.
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    package func stop() {
        reloadTask?.cancel()
    }

    package func reset() {
        configurationRevision += 1
        configurationSaveTask = nil
        projectLoadTask?.cancel()
        projectLoadTask = nil
        projectLoadInventory = nil
        reloadTask?.cancel()
        reloadTask = nil
        isReloading = false
        reloadError = nil
        reloadRevision += 1
        isProjectReloadRequired = false
        stop()
        projectLoadID = UUID()
        project = nil
        workspaceURL = nil
        reactorPath = nil
        acceptedProjectInventory = nil
        projectState = .idle
        selectedProfiles = []
        customProfiles = []
        skipTests = false
        settingsPath = nil
        localRepositoryPath = nil
        mavenExecutablePath = nil
        javaHomePath = nil
        configurationFingerprint = nil
        fingerprintRevision += 1
        configurationSaveError = nil
        isReloadRequired = false
    }

    private func applyStoredConfiguration(
        _ stored: MavenStoredConfiguration?,
        project: MavenProject?
    ) {
        let defaults = project?.profiles.filter(\.isActiveByDefault).map(\.id) ?? []
        let portable = stored?.portable
        selectedProfiles = Set(portable?.selectedProfiles ?? defaults)
        customProfiles = normalizedProfiles(portable?.customProfiles ?? [])
        skipTests = portable?.skipTests ?? false
        settingsPath = normalizedLocalPath(stored?.local?.settingsPath)
        localRepositoryPath = normalizedLocalPath(stored?.local?.localRepositoryPath)
        mavenExecutablePath = normalizedLocalPath(stored?.local?.mavenExecutablePath)
        javaHomePath = normalizedLocalPath(stored?.local?.javaHomePath)
    }

    private func configurationDidChange() {
        reloadRevision += 1
        configurationSaveError = nil
        persistConfiguration()
        guard let workspaceURL, let applyConfigurationToJava else {
            isReloadRequired = isProjectReloadRequired || configurationFingerprint != nil
            refreshConfigurationFingerprint()
            return
        }
        do {
            // A running session took the change, or the next start reads it;
            // either way JDT LS holds this configuration from now on.
            _ = try applyConfigurationToJava(workspaceURL)
            javaConfigurationError = nil
            isReloadRequired = isProjectReloadRequired
            refreshConfigurationFingerprint(establishBaseline: true)
        } catch {
            javaConfigurationError = error.localizedDescription
            isReloadRequired = true
        }
    }

    private func refreshConfigurationFingerprint(establishBaseline: Bool = false) {
        guard let workspaceURL, let context = launchContext else { return }
        fingerprintRevision += 1
        let revision = fingerprintRevision
        let operations = mavenOperations
        Task { [weak self] in
            let fingerprint = await Task.detached(priority: .utility) {
                try? operations.mavenLaunchPlan(
                    at: workspaceURL,
                    context: context,
                    module: nil,
                    goals: [MavenLifecyclePhase.validate.rawValue]
                ).configurationFingerprint
            }.value
            guard let self, self.fingerprintRevision == revision, let fingerprint else { return }
            if establishBaseline || self.configurationFingerprint == nil {
                self.configurationFingerprint = fingerprint
                self.isReloadRequired = self.isProjectReloadRequired
            } else {
                self.isReloadRequired = self.isProjectReloadRequired || self.configurationFingerprint != fingerprint
            }
        }
    }

    private func recordConfigurationFingerprint(_ fingerprint: String) {
        if let configurationFingerprint {
            isReloadRequired = isProjectReloadRequired || configurationFingerprint != fingerprint
        } else {
            configurationFingerprint = fingerprint
            isReloadRequired = isProjectReloadRequired
        }
    }

    /// API callers must await the actual write before reporting that settings were saved.
    package func saveConfiguration() async -> String? {
        guard let workspaceURL, let reactorPath else {
            return "No Maven project is loaded"
        }
        persistConfiguration()
        let revision = configurationRevision
        let error = await configurationSaveTask?.value
        guard configurationRevision == revision,
              self.workspaceURL == workspaceURL, self.reactorPath == reactorPath else {
            return "Maven settings changed while saving. Inspect the current settings before retrying."
        }
        return error
    }

    private func persistConfiguration() {
        guard let workspaceURL, let reactorPath else { return }
        configurationRevision += 1
        let revision = configurationRevision
        let stored = MavenStoredConfiguration(
            portable: MavenPortableConfiguration(
                selectedProfiles: selectedProfiles.sorted(),
                customProfiles: normalizedProfiles(customProfiles),
                skipTests: skipTests
            ),
            local: MavenLocalConfiguration(
                settingsPath: settingsPath,
                localRepositoryPath: localRepositoryPath,
                mavenExecutablePath: mavenExecutablePath,
                javaHomePath: javaHomePath
            )
        )
        let writer = configurationWriter
        configurationSaveTask = Task { [weak self] in
            let errorMessage = await writer.save(
                revision: revision,
                configuration: stored,
                workspaceURL: workspaceURL,
                reactorPath: reactorPath
            )
            if let self, self.configurationRevision == revision {
                self.configurationSaveError = errorMessage
            }
            return errorMessage
        }
    }

    private func isValidProfile(_ value: String) -> Bool {
        !value.isEmpty
            && !value.contains(",")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func normalizedProfiles(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isValidProfile)))
            .sorted()
    }

    private func normalizedLocalPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
    }

    nonisolated private static func relativePath(from rootURL: URL, to childURL: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let child = childURL.standardizedFileURL.path
        if root == child { return "." }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard child.hasPrefix(prefix) else { return "." }
        return String(child.dropFirst(prefix.count))
    }
}

private struct MavenProjectLoadResult: Sendable {
    let project: MavenProject?
    let reactorPath: String?
    let stored: MavenStoredConfiguration?
    let errorMessage: String?
}

private struct MavenPlanResult: Sendable {
    let plan: MavenLaunchPlan?
    let errorMessage: String?
}

private actor MavenConfigurationWriter {
    private let store: (any MavenConfigurationStoring)?
    private var latestRevision = 0

    init(store: (any MavenConfigurationStoring)?) {
        self.store = store
    }

    func load(
        workspaceURL: URL,
        reactorPath: String
    ) throws -> MavenStoredConfiguration {
        try store?.loadMavenConfiguration(
            workspaceURL: workspaceURL,
            reactorPath: reactorPath
        ) ?? MavenStoredConfiguration(portable: nil, local: nil)
    }

    func save(
        revision: Int,
        configuration: MavenStoredConfiguration,
        workspaceURL: URL,
        reactorPath: String
    ) -> String? {
        guard revision > latestRevision else { return nil }
        latestRevision = revision
        do {
            try store?.saveMavenConfiguration(
                configuration,
                workspaceURL: workspaceURL,
                reactorPath: reactorPath
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
