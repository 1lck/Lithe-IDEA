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
    @Published private(set) var isDiscovering = false

    var onRuntimeChanged: (() -> Void)?

    private let runtimeLocator: any RuntimeLocator
    private let toolchainSource: (any ProjectToolchainConfigurationSource)?
    private var discoveryTask: Task<Void, Never>?
    private var localToolchains = ProjectToolchainSelection()

    private let settingsStore: ProjectRuntimeSettingsStore

    init(
        runtimeLocator: any RuntimeLocator,
        store: any KeyValueStore,
        toolchainSource: (any ProjectToolchainConfigurationSource)? = nil
    ) {
        self.runtimeLocator = runtimeLocator
        self.settingsStore = ProjectRuntimeSettingsStore(store: store)
        self.toolchainSource = toolchainSource
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

    func javaLanguageServerExecutable() -> URL? {
        runtimeLocator.javaLanguageServerExecutable()
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
