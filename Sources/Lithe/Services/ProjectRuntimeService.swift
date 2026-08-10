import Foundation

enum ProjectRuntimeProcessKind: Sendable {
    case java
    case maven
}

@MainActor
final class ProjectRuntimeService: ObservableObject {
    @Published private(set) var projectURL: URL?
    @Published private(set) var settings = ProjectRuntimeSettings()
    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate] = []
    @Published private(set) var mavenRuntimes: [MavenRuntimeCandidate] = []
    @Published private(set) var javaEnvironmentReport: JavaEnvironmentReport?
    @Published private(set) var isDiscovering = false

    var onRuntimeChanged: (() -> Void)?

    private let runtimeLocator: any RuntimeLocator
    private let toolDiscovery: any RuntimeToolDiscovery
    private let toolchainSource: (any ProjectToolchainConfigurationSource)?
    private var discoveryTask: Task<Void, Never>?
    private var localToolchains = ProjectToolchainSelection()

    private let settingsStore: ProjectRuntimeSettingsStore

    init(
        runtimeLocator: any RuntimeLocator,
        store: any KeyValueStore,
        toolchainSource: (any ProjectToolchainConfigurationSource)? = nil,
        toolDiscovery: (any RuntimeToolDiscovery)? = nil
    ) {
        self.runtimeLocator = runtimeLocator
        self.settingsStore = ProjectRuntimeSettingsStore(store: store)
        self.toolchainSource = toolchainSource
        self.toolDiscovery = toolDiscovery ?? DefaultRuntimeToolDiscovery()
    }

    deinit {
        discoveryTask?.cancel()
    }

    func openProject(at url: URL) {
        discoveryTask?.cancel()
        let normalizedURL = url.standardizedFileURL
        projectURL = normalizedURL
        settings = settingsStore.load(for: normalizedURL)
        localToolchains = toolchainSource?.loadLocalToolchains(at: normalizedURL) ?? ProjectToolchainSelection()
        apply(localToolchains, to: &settings)
        javaRuntimes = []
        mavenRuntimes = []
        javaEnvironmentReport = .checking(for: normalizedURL)
        discoveryTask = Task { [weak self] in
            await self?.refreshAvailableRuntimes()
        }
    }

    func closeProject() {
        discoveryTask?.cancel()
        discoveryTask = nil
        projectURL = nil
        settings = ProjectRuntimeSettings()
        localToolchains = ProjectToolchainSelection()
        javaRuntimes = []
        mavenRuntimes = []
        javaEnvironmentReport = nil
        isDiscovering = false
    }

    func updateJavaHomePath(_ path: String) {
        var next = settings
        next.javaHomePath = normalizedPath(path)
        updateSettings(next)
    }

    func updateMavenHomeSelection(_ selection: MavenHomeSelection) {
        var next = settings
        next.mavenHomeSelection = selection
        updateSettings(next)
    }

    func updateMavenHomePath(_ path: String) {
        var next = settings
        next.mavenHomePath = normalizedPath(path)
        updateSettings(next)
    }

    func updateMavenJavaHomePath(_ path: String) {
        var next = settings
        next.mavenJavaHomePath = normalizedPath(path)
        updateSettings(next)
    }

    func updateSettings(_ next: ProjectRuntimeSettings) {
        settings = next
        if let projectURL {
            settingsStore.save(next, for: projectURL)
            localToolchains = toolchainSelection(from: next)
            try? toolchainSource?.saveLocalToolchains(localToolchains, at: projectURL)
        }
        refreshJavaEnvironmentReport(using: javaRuntimes)
        onRuntimeChanged?()
    }

    func refreshAvailableRuntimes() async {
        let targetProjectURL = projectURL
        isDiscovering = true
        let runtimeLocator = runtimeLocator
        let result = await Task.detached(priority: .utility) {
            runtimeLocator.discover()
        }.value
        guard !Task.isCancelled, projectURL == targetProjectURL else { return }
        javaRuntimes = result.javaRuntimes
        mavenRuntimes = result.mavenRuntimes
        refreshJavaEnvironmentReport(using: result.javaRuntimes)
        isDiscovering = false
        onRuntimeChanged?()
    }

    func javaHomeURL(overridePath: String? = nil) -> URL? {
        if let overridePath,
           !normalizedPath(overridePath).isEmpty {
            return runtimeLocator.validJavaHome(path: normalizedPath(overridePath))
        }
        let paths = [localToolchains.javaHomePath, settings.javaHomePath, runtimeLocator.environment()["JAVA_HOME"]]
        for path in paths.compactMap({ $0 }).map(normalizedPath).filter({ !$0.isEmpty }) {
            if let home = runtimeLocator.validJavaHome(path: path) { return home }
        }
        return runtimeLocator.discover()
            .javaRuntimes
            .first
            .flatMap { runtimeLocator.validJavaHome(path: $0.homePath) }
    }

    func javaExecutableURL(overridePath: String? = nil) -> URL? {
        javaHomeURL(overridePath: overridePath)?.appendingPathComponent("bin/java")
    }

    /// Resolves only explicit project/settings/environment JDK paths.  Unlike
    /// `javaExecutableURL()`, this method never falls back to discovery or
    /// probes `java -version`, so capability checks can remain inert.
    func configuredJavaExecutableURL(overridePath: String? = nil) -> URL? {
        let paths: [String?]
        if let overridePath, !normalizedPath(overridePath).isEmpty {
            paths = [overridePath]
        } else {
            paths = [
                localToolchains.javaHomePath,
                settings.javaHomePath,
                runtimeLocator.environment()["JAVA_HOME"]
            ]
        }
        for path in paths.compactMap({ $0 }).map(normalizedPath).filter({ !$0.isEmpty }) {
            if let home = runtimeLocator.validJavaHome(path: path) {
                return home.appendingPathComponent("bin/java")
            }
        }
        return nil
    }

    func jdbExecutableURL(
        overridePath: String? = nil,
        for processKind: ProjectRuntimeProcessKind = .java
    ) -> URL? {
        let home = processKind == .maven
            ? mavenJavaHomeURL(overridePath: overridePath)
            : javaHomeURL(overridePath: overridePath)
        if let home {
            let candidate = home.appendingPathComponent("bin/jdb")
            if runtimeLocator.isExecutable(at: candidate) {
                return candidate
            }
        }
        return runtimeLocator.systemJDBExecutable()
    }

    func mavenJavaHomeURL(overridePath: String? = nil) -> URL? {
        if let overridePath,
           !normalizedPath(overridePath).isEmpty {
            return runtimeLocator.validJavaHome(path: normalizedPath(overridePath))
        }
        let paths = [
            localToolchains.mavenJavaHomePath,
            localToolchains.javaHomePath,
            settings.mavenJavaHomePath,
            settings.javaHomePath,
            runtimeLocator.environment()["JAVA_HOME"]
        ]
        for path in paths.compactMap({ $0 }).map(normalizedPath).filter({ !$0.isEmpty }) {
            if let home = runtimeLocator.validJavaHome(path: path) { return home }
        }
        return javaHomeURL()
    }

    func environment(
        for processKind: ProjectRuntimeProcessKind,
        javaHomeOverride: String? = nil
    ) -> [String: String] {
        var environment = runtimeLocator.environment()
        let home = processKind == .maven
            ? mavenJavaHomeURL(overridePath: javaHomeOverride)
            : javaHomeURL(overridePath: javaHomeOverride)
        if let home {
            environment["JAVA_HOME"] = home.path
            let path = environment["PATH"] ?? ""
            let javaBin = home.appendingPathComponent("bin").path
            environment["PATH"] = javaBin + (path.isEmpty ? "" : ":" + path)
        }
        return environment
    }

    /// Base environment for language-neutral processes such as Go, Python and
    /// Node. Overrides are layered on top without injecting Java variables.
    func processEnvironment(overrides: [String: String] = [:]) -> [String: String] {
        runtimeLocator.environment().merging(overrides) { _, override in override }
    }

    /// Returns all known candidates in preference order.  The platform
    /// adapter can add project-local, Homebrew, Xcode, or registry sources;
    /// the locator fallback keeps existing non-platform implementations fully
    /// compatible.
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] {
        guard !command.isEmpty, !command.contains("/") else { return [] }
        let environment = runtimeLocator.environment()
        let discovered = toolDiscovery.candidates(
            for: command,
            projectURL: projectURL,
            environment: environment
        )
        var candidates = discovered
        var seen = Set(discovered.map { $0.executableURL.standardizedFileURL.path })
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidateURL = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(command)
                .standardizedFileURL
            guard runtimeLocator.isExecutable(at: candidateURL),
                  seen.insert(candidateURL.path).inserted else { continue }
            candidates.append(RuntimeToolCandidate(
                command: command,
                executableURL: candidateURL,
                source: .path,
                detail: String(directory)
            ))
        }
        return candidates
    }

    func toolGuidance(_ command: String) -> RuntimeToolGuidance {
        toolDiscovery.guidance(
            for: command,
            projectURL: projectURL,
            environment: runtimeLocator.environment()
        )
    }

    func missingToolMessage(_ command: String) -> String {
        let guidance = toolGuidance(command)
        return guidance.message
    }

    private func refreshJavaEnvironmentReport(using discoveredJavaRuntimes: [JavaRuntimeCandidate]) {
        guard let projectURL else {
            javaEnvironmentReport = nil
            return
        }

        let configuredPath = normalizedPath(settings.javaHomePath)
        if !configuredPath.isEmpty,
           runtimeLocator.validJavaHome(path: configuredPath) == nil {
            javaEnvironmentReport = JavaEnvironmentReport(
                status: .configuredJDKInvalid(path: configuredPath),
                projectURL: projectURL,
                javaHomePath: configuredPath,
                javaExecutablePath: nil,
                jdbExecutablePath: nil
            )
            return
        }

        let javaHome: URL? = if !configuredPath.isEmpty {
            runtimeLocator.validJavaHome(path: configuredPath)
        } else {
            discoveredJavaRuntimes.first.flatMap { runtimeLocator.validJavaHome(path: $0.homePath) }
        }
        guard let javaHome else {
            javaEnvironmentReport = JavaEnvironmentReport(
                status: .jdkMissing,
                projectURL: projectURL,
                javaHomePath: nil,
                javaExecutablePath: nil,
                jdbExecutablePath: runtimeLocator.systemJDBExecutable()?.path
            )
            return
        }

        let javaExecutable = javaHome.appendingPathComponent("bin/java")
        let bundledJDB = javaHome.appendingPathComponent("bin/jdb")
        let jdbExecutable = runtimeLocator.isExecutable(at: bundledJDB)
            ? bundledJDB
            : runtimeLocator.systemJDBExecutable()
        guard let jdbExecutable else {
            javaEnvironmentReport = JavaEnvironmentReport(
                status: .jdbMissing,
                projectURL: projectURL,
                javaHomePath: javaHome.path,
                javaExecutablePath: javaExecutable.path,
                jdbExecutablePath: nil
            )
            return
        }

        javaEnvironmentReport = JavaEnvironmentReport(
            status: .ready,
            projectURL: projectURL,
            javaHomePath: javaHome.path,
            javaExecutablePath: javaExecutable.path,
            jdbExecutablePath: jdbExecutable.path
        )
    }

    /// Resolves a bare program name without starting a process. Returns nil
    /// when no candidate is executable.
    func executableOnPath(_ command: String) -> URL? {
        executableCandidates(command).first?.executableURL
    }

    func mavenExecutable(for project: MavenProject) -> URL? {
        mavenExecutable(at: project.rootURL)
    }

    func mavenExecutable(at rootURL: URL) -> URL? {
        let configured = localToolchains.mavenExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            let candidate = configured.hasPrefix("/")
                ? URL(fileURLWithPath: configured)
                : rootURL.appendingPathComponent(configured)
            if runtimeLocator.isExecutable(at: candidate.standardizedFileURL) {
                return candidate.standardizedFileURL
            }
        }
        let wrapper = rootURL.appendingPathComponent("mvnw")
        switch settings.mavenHomeSelection {
        case .wrapper:
            return runtimeLocator.isExecutable(at: wrapper) ? wrapper : nil
        case .custom:
            return runtimeLocator.mavenExecutable(forHomePath: settings.mavenHomePath)
        case .automatic:
            if runtimeLocator.isExecutable(at: wrapper) {
                return wrapper
            }
            return runtimeLocator.systemMavenExecutable()
        }
    }

    /// Resolves a Gradle wrapper before falling back to a system Gradle. The
    /// executable check is delegated to RuntimeLocator so platform adapters
    /// can apply their own permissions and path rules.
    func gradleExecutable(at rootURL: URL) -> URL? {
        let normalizedRoot = rootURL.standardizedFileURL
        let wrappers = [
            normalizedRoot.appendingPathComponent("gradlew"),
            normalizedRoot.appendingPathComponent("gradlew.bat")
        ]
        if let wrapper = wrappers.first(where: { runtimeLocator.isExecutable(at: $0) }) {
            return wrapper
        }
        return executableOnPath("gradle")
    }

    func activeJavaRuntime() -> JavaRuntimeCandidate? {
        guard let home = javaHomeURL()?.path else { return nil }
        return javaRuntimes.first { $0.homePath == home }
    }

    func activeMavenRuntime(for project: MavenProject) -> MavenRuntimeCandidate? {
        guard let executable = mavenExecutable(for: project)?.path else { return nil }
        return mavenRuntimes.first { $0.executablePath == executable }
    }

    func runConfigurationToolchainCandidates(
        for project: MavenProject?,
        projectRoot: URL? = nil
    ) -> [ProjectToolchainCandidate] {
        var result: [ProjectToolchainCandidate] = []
        let java = activeJavaRuntime() ?? javaHomeURL().flatMap(runtimeLocator.javaRuntime(at:))
        if let java {
            result.append(ProjectToolchainCandidate(
                id: "project-jdk",
                type: "java",
                version: java.version,
                vendor: java.vendor
            ))
        }
        let maven = project.flatMap(activeMavenRuntime)
            ?? projectRoot.flatMap { root in
                mavenExecutable(at: root).flatMap(runtimeLocator.mavenRuntime(at:))
            }
        if let maven {
            result.append(ProjectToolchainCandidate(
                id: "project-maven",
                type: "maven",
                version: maven.version,
                vendor: ""
            ))
        }
        return result
    }

    private func normalizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private func toolchainSelection(from settings: ProjectRuntimeSettings) -> ProjectToolchainSelection {
        let mavenExecutable: String
        switch settings.mavenHomeSelection {
        case .wrapper:
            mavenExecutable = "./mvnw"
        case .custom where !settings.mavenHomePath.isEmpty:
            mavenExecutable = URL(fileURLWithPath: settings.mavenHomePath)
                .appendingPathComponent("bin/mvn")
                .path
        case .automatic, .custom:
            mavenExecutable = ""
        }
        return ProjectToolchainSelection(
            javaHomePath: settings.javaHomePath,
            mavenExecutablePath: mavenExecutable,
            mavenJavaHomePath: settings.mavenJavaHomePath
        )
    }

    private func apply(
        _ selection: ProjectToolchainSelection,
        to settings: inout ProjectRuntimeSettings
    ) {
        if !selection.javaHomePath.isEmpty {
            settings.javaHomePath = selection.javaHomePath
        }
        if !selection.mavenJavaHomePath.isEmpty {
            settings.mavenJavaHomePath = selection.mavenJavaHomePath
        }
        let executable = selection.mavenExecutablePath
        if executable == "./mvnw" || executable == "mvnw" {
            settings.mavenHomeSelection = .wrapper
        } else if !executable.isEmpty {
            let binDirectory = URL(fileURLWithPath: executable).deletingLastPathComponent()
            settings.mavenHomeSelection = .custom
            settings.mavenHomePath = binDirectory.lastPathComponent == "bin"
                ? binDirectory.deletingLastPathComponent().path
                : binDirectory.path
        }
    }

}

private struct ProjectRuntimeSettingsStore {
    private static let prefix = "lithe.project-runtime."
    private let store: any KeyValueStore

    init(store: any KeyValueStore) {
        self.store = store
    }

    func load(for projectURL: URL) -> ProjectRuntimeSettings {
        guard let data = store.data(forKey: Self.key(for: projectURL)),
              let settings = try? JSONDecoder().decode(ProjectRuntimeSettings.self, from: data) else {
            return ProjectRuntimeSettings()
        }
        return settings
    }

    func save(_ settings: ProjectRuntimeSettings, for projectURL: URL) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        store.set(data, forKey: Self.key(for: projectURL))
    }

    private static func key(for projectURL: URL) -> String {
        prefix + projectURL.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
    }
}
