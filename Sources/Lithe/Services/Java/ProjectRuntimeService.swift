import Foundation
import LitheCoreContracts

enum ProjectRuntimeProcessKind: Sendable {
    case java
    case maven
}

extension ProjectRuntimeService: RunRuntimePort {}

extension ProjectRuntimeService: LanguageToolRuntimePort {
    package func languageToolProcessEnvironment() -> [String: String] {
        processEnvironment()
    }

    package func missingLanguageToolMessage(_ name: String) -> String {
        missingToolMessage(name)
    }
}

extension ProjectRuntimeService: MavenRuntimePort {
    package func mavenExecutable(for project: MavenProject) -> URL? {
        mavenExecutable(for: project, overridePath: nil)
    }

    package func mavenProcessEnvironment() -> [String: String] {
        environment(for: .maven)
    }
}

@MainActor
final class ProjectRuntimeService: ObservableObject {
    enum JavaLanguageServerRuntimePreparation: Equatable {
        case unprepared
        case ready(executableURL: URL)
        case failed(message: String)
    }

    @Published private(set) var projectURL: URL?
    @Published private(set) var javaRuntimes: [JavaRuntimeCandidate] = []
    @Published private(set) var mavenRuntimes: [MavenRuntimeCandidate] = []
    @Published private(set) var javaEnvironmentReport: JavaEnvironmentReport?
    @Published private(set) var isDiscovering = false
    private var activeServiceJavaHomePath = ""

    private let runtimeLocator: any RuntimeLocator
    private let toolDiscovery: any RuntimeToolDiscovery
    private var discoveryTask: Task<Void, Never>?
    private var activeDiscoveryID: UUID?
    private var javaLanguageServerRuntimePreparation: JavaLanguageServerRuntimePreparation = .unprepared

    init(
        runtimeLocator: any RuntimeLocator,
        store: any KeyValueStore,
        toolDiscovery: (any RuntimeToolDiscovery)? = nil
    ) {
        self.runtimeLocator = runtimeLocator
        _ = store
        self.toolDiscovery = toolDiscovery ?? DefaultRuntimeToolDiscovery()
    }

    deinit {
        discoveryTask?.cancel()
    }

    func openProject(at url: URL) {
        discoveryTask?.cancel()
        activeDiscoveryID = nil
        let normalizedURL = url.standardizedFileURL
        projectURL = normalizedURL
        javaRuntimes = []
        mavenRuntimes = []
        javaEnvironmentReport = .checking(for: normalizedURL)
        javaLanguageServerRuntimePreparation = .unprepared
        discoveryTask = nil
    }

    func closeProject() {
        discoveryTask?.cancel()
        discoveryTask = nil
        activeDiscoveryID = nil
        projectURL = nil
        javaRuntimes = []
        mavenRuntimes = []
        javaEnvironmentReport = nil
        isDiscovering = false
        activeServiceJavaHomePath = ""
        javaLanguageServerRuntimePreparation = .unprepared
    }

    func setActiveServiceJavaHomePath(_ path: String) {
        activeServiceJavaHomePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refreshAvailableRuntimes() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        await performRuntimeRefresh()
    }

    private func performRuntimeRefresh() async {
        let targetProjectURL = projectURL
        let discoveryID = UUID()
        activeDiscoveryID = discoveryID
        isDiscovering = true
        defer {
            if activeDiscoveryID == discoveryID {
                activeDiscoveryID = nil
                isDiscovering = false
            }
        }
        let runtimeLocator = runtimeLocator
        let result = await Task.detached(priority: .utility) {
            runtimeLocator.discover()
        }.value
        guard !Task.isCancelled,
              projectURL == targetProjectURL,
              activeDiscoveryID == discoveryID else { return }
        javaRuntimes = result.javaRuntimes
        mavenRuntimes = result.mavenRuntimes
        refreshJavaEnvironmentReport(using: result.javaRuntimes)
        isDiscovering = false
    }

    func javaHomeURL(overridePath: String? = nil) -> URL? {
        if let overridePath {
            let normalizedPath = normalizedOverridePath(overridePath)
            if !normalizedPath.isEmpty {
                return runtimeLocator.validJavaHome(path: normalizedPath)
            }
        }
        let paths = [runtimeLocator.environment()["JAVA_HOME"]]
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
        if let overridePath {
            let normalizedPath = normalizedOverridePath(overridePath)
            paths = normalizedPath.isEmpty ? [runtimeLocator.environment()["JAVA_HOME"]] : [normalizedPath]
        } else {
            paths = [runtimeLocator.environment()["JAVA_HOME"]]
        }
        for path in paths.compactMap({ $0 }).map(normalizedPath).filter({ !$0.isEmpty }) {
            if let home = runtimeLocator.validJavaHome(path: path) {
                return home.appendingPathComponent("bin/java")
            }
        }
        return nil
    }

    func isJavaLanguageServerRuntimePrepared() -> Bool {
        if case .ready = javaLanguageServerRuntimePreparation { return true }
        return false
    }

    /// Probes only the application-owned Temurin 21 runtime. Project JDKs and
    /// user environment variables never influence the language-server process.
    @discardableResult
    func prepareJavaLanguageServerRuntime() async -> JavaLanguageServerRuntimePreparation {
        if javaLanguageServerRuntimePreparation != .unprepared {
            return javaLanguageServerRuntimePreparation
        }
        let runtimeLocator = runtimeLocator
        let preparation = await Task.detached(priority: .utility) {
            guard let home = runtimeLocator.bundledJdkHome(),
                  let runtime = runtimeLocator.javaRuntime(at: home) else {
                return JavaLanguageServerRuntimePreparation.failed(
                    message: "The bundled Temurin JDK 21 is missing or invalid. Reinstall Lithe."
                )
            }
            guard runtime.majorVersion == 21,
                  let validHome = runtimeLocator.validJavaHome(path: runtime.homePath) else {
                return JavaLanguageServerRuntimePreparation.failed(
                    message: "The bundled JDTLS runtime must be Temurin JDK 21; found \(runtime.version). Reinstall Lithe."
                )
            }
            return JavaLanguageServerRuntimePreparation.ready(
                executableURL: validHome.appendingPathComponent("bin/java")
            )
        }.value
        guard !Task.isCancelled else { return .unprepared }
        javaLanguageServerRuntimePreparation = preparation
        return preparation
    }

    func javaLanguageServerExecutableURL() -> URL? {
        guard case .ready(let executableURL) = javaLanguageServerRuntimePreparation else {
            return nil
        }
        return executableURL
    }

    func javaLanguageServerRuntimeFailureMessage() -> String? {
        guard case .failed(let message) = javaLanguageServerRuntimePreparation else {
            return nil
        }
        return message
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
        if let overridePath {
            let normalizedPath = normalizedOverridePath(overridePath)
            if !normalizedPath.isEmpty {
                return runtimeLocator.validJavaHome(path: normalizedPath)
            }
        }
        let paths = [runtimeLocator.environment()["JAVA_HOME"]]
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

        let javaHome = discoveredJavaRuntimes.first.flatMap { runtimeLocator.validJavaHome(path: $0.homePath) }
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

    func executableURL(at path: String) -> URL? {
        let normalized = (path as NSString)
            .expandingTildeInPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let url = URL(fileURLWithPath: normalized).standardizedFileURL
        return runtimeLocator.isExecutable(at: url) ? url : nil
    }

    package func mavenExecutable(for project: MavenProject, overridePath: String? = nil) -> URL? {
        mavenExecutable(at: project.rootURL, overridePath: overridePath)
    }

    func mavenExecutable(at rootURL: URL, overridePath: String? = nil) -> URL? {
        let configured = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty {
            let resolved = configured.hasPrefix("/")
                ? URL(fileURLWithPath: configured)
                : rootURL.appendingPathComponent(configured)
            let candidates = [
                resolved,
                resolved.appendingPathComponent("bin/mvn")
            ]
            if let candidate = candidates.first(where: { runtimeLocator.isExecutable(at: $0.standardizedFileURL) }) {
                return candidate.standardizedFileURL
            }
            return nil
        }
        let wrapper = rootURL.appendingPathComponent("mvnw")
        if runtimeLocator.isExecutable(at: wrapper) {
            return wrapper
        }
        return runtimeLocator.systemMavenExecutable()
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
        projectRoot: URL? = nil,
        javaHomeOverride: String? = nil,
        mavenExecutableOverride: String? = nil
    ) -> [ProjectToolchainCandidate] {
        var result: [ProjectToolchainCandidate] = []
        let java = javaHomeURL(overridePath: javaHomeOverride).flatMap(runtimeLocator.javaRuntime(at:))
        if let java {
            result.append(ProjectToolchainCandidate(
                id: "project-jdk",
                type: "java",
                version: java.version,
                vendor: java.vendor
            ))
        }
        let maven = projectRoot.flatMap { root in
            mavenExecutable(at: root, overridePath: mavenExecutableOverride)
                .flatMap(runtimeLocator.mavenRuntime(at:))
        } ?? project.flatMap(activeMavenRuntime)
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

    private func normalizedOverridePath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "" }
        let normalized = normalizedPath(trimmedPath)
        guard !(normalized as NSString).isAbsolutePath,
              let projectURL else { return normalized }
        return projectURL.appendingPathComponent(normalized).standardizedFileURL.path
    }

    private func normalizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

}
