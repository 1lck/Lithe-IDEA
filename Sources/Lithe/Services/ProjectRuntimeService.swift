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

    private var discoveryTask: Task<Void, Never>?

    deinit {
        discoveryTask?.cancel()
    }

    func openProject(at url: URL) {
        discoveryTask?.cancel()
        let normalizedURL = url.standardizedFileURL
        projectURL = normalizedURL
        settings = ProjectRuntimeSettingsStore.load(for: normalizedURL)
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
            ProjectRuntimeSettingsStore.save(next, for: projectURL)
        }
        onRuntimeChanged?()
    }

    func refreshAvailableRuntimes() async {
        let targetProjectURL = projectURL
        isDiscovering = true
        let environment = ProcessInfo.processInfo.environment
        let result = await Task.detached(priority: .utility) {
            RuntimeDiscovery.discover(environment: environment)
        }.value
        guard !Task.isCancelled, projectURL == targetProjectURL else { return }
        javaRuntimes = result.javaRuntimes
        mavenRuntimes = result.mavenRuntimes
        isDiscovering = false
    }

    func javaHomeURL(overridePath: String? = nil) -> URL? {
        if let overridePath,
           !normalizedPath(overridePath).isEmpty {
            return Self.validJavaHome(normalizedPath(overridePath))
        }
        let paths = [settings.javaHomePath, ProcessInfo.processInfo.environment["JAVA_HOME"]]
        for path in paths.compactMap({ $0 }).map(normalizedPath).filter({ !$0.isEmpty }) {
            if let home = Self.validJavaHome(path) { return home }
        }
        return RuntimeDiscovery.discover(environment: ProcessInfo.processInfo.environment)
            .javaRuntimes
            .first
            .flatMap { Self.validJavaHome($0.homePath) }
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
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return ["/opt/homebrew/bin/jdb", "/usr/local/bin/jdb", "/usr/bin/jdb"]
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    func mavenJavaHomeURL(overridePath: String? = nil) -> URL? {
        if let overridePath,
           !normalizedPath(overridePath).isEmpty {
            return Self.validJavaHome(normalizedPath(overridePath))
        }
        let paths = [settings.mavenJavaHomePath, settings.javaHomePath, ProcessInfo.processInfo.environment["JAVA_HOME"]]
        for path in paths.compactMap({ $0 }).map(normalizedPath).filter({ !$0.isEmpty }) {
            if let home = Self.validJavaHome(path) { return home }
        }
        return javaHomeURL()
    }

    func environment(
        for processKind: ProjectRuntimeProcessKind,
        javaHomeOverride: String? = nil
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
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
        let wrapper = project.rootURL.appendingPathComponent("mvnw")
        switch settings.mavenHomeSelection {
        case .wrapper:
            return FileManager.default.isExecutableFile(atPath: wrapper.path) ? wrapper : nil
        case .custom:
            return RuntimeDiscovery.mavenExecutable(forHomePath: settings.mavenHomePath)
        case .automatic:
            if FileManager.default.isExecutableFile(atPath: wrapper.path) {
                return wrapper
            }
            return RuntimeDiscovery.systemMavenExecutable(environment: ProcessInfo.processInfo.environment)
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

    private func normalizedPath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    private static func validJavaHome(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        let executable = url.appendingPathComponent("bin/java")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? url : nil
    }
}

private enum ProjectRuntimeSettingsStore {
    private static let prefix = "lithe.project-runtime."

    static func load(for projectURL: URL) -> ProjectRuntimeSettings {
        guard let data = UserDefaults.standard.data(forKey: key(for: projectURL)),
              let settings = try? JSONDecoder().decode(ProjectRuntimeSettings.self, from: data) else {
            return ProjectRuntimeSettings()
        }
        return settings
    }

    static func save(_ settings: ProjectRuntimeSettings, for projectURL: URL) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key(for: projectURL))
    }

    private static func key(for projectURL: URL) -> String {
        prefix + projectURL.standardizedFileURL.path.replacingOccurrences(of: "/", with: "_")
    }
}

fileprivate enum RuntimeDiscovery {
    static func discover(environment: [String: String]) -> RuntimeDiscoveryResult {
        let javaRuntimes = discoverJavaHomes(environment: environment)
            .compactMap(probeJavaHome)
            .sorted { lhs, rhs in
                lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
            }
        let mavenRuntimes = discoverMavenExecutables(environment: environment)
            .compactMap(probeMaven)
            .sorted { lhs, rhs in
                lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
            }
        return RuntimeDiscoveryResult(javaRuntimes: javaRuntimes, mavenRuntimes: mavenRuntimes)
    }

    private static func discoverJavaHomes(environment: [String: String]) -> [URL] {
        var paths: [String: URL] = [:]
        func add(_ path: String?) {
            guard let path,
                  let home = validJavaHome(path) else { return }
            let identity = home.resolvingSymlinksInPath().path
            if paths[identity] == nil {
                paths[identity] = home
            }
        }

        add(environment["JAVA_HOME"])
        for path in javaHomeOutput() {
            add(path)
        }

        for root in [
            "/Library/Java/JavaVirtualMachines",
            NSHomeDirectory() + "/Library/Java/JavaVirtualMachines"
        ] {
            for entry in directoryNames(at: root) {
                add(root + "/" + entry + "/Contents/Home")
            }
        }

        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for entry in directoryNames(at: root) where entry.hasPrefix("openjdk") {
                add(root + "/" + entry + "/libexec/openjdk.jdk/Contents/Home")
            }
        }

        return paths.values.sorted { $0.path < $1.path }
    }

    private static func discoverMavenExecutables(environment: [String: String]) -> [URL] {
        var paths = Set<String>()
        func add(_ path: String?) {
            guard let path else { return }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard FileManager.default.isExecutableFile(atPath: url.path) else { return }
            paths.insert(url.path)
        }

        if let mavenHome = environment["MAVEN_HOME"] {
            add(URL(fileURLWithPath: mavenHome).appendingPathComponent("bin/mvn").path)
        }
        for component in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            add(URL(fileURLWithPath: component).appendingPathComponent("mvn").path)
        }
        for path in [
            "/opt/homebrew/opt/maven/bin/mvn",
            "/opt/homebrew/bin/mvn",
            "/usr/local/opt/maven/bin/mvn",
            "/usr/local/bin/mvn",
            "/usr/bin/mvn"
        ] {
            add(path)
        }
        return paths.sorted().map(URL.init(fileURLWithPath:))
    }

    private static func probeJavaHome(_ home: URL) -> JavaRuntimeCandidate? {
        let output = commandOutput(
            executable: home.appendingPathComponent("bin/java"),
            arguments: ["-version"]
        )
        guard let version = firstCapture(pattern: #"version\s+\"([^\"]+)\""#, in: output) else {
            return nil
        }
        let vendor = output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains("Runtime Environment") || $0.contains("VM") })?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return JavaRuntimeCandidate(homePath: home.path, version: version, vendor: vendor)
    }

    private static func probeMaven(_ executable: URL) -> MavenRuntimeCandidate? {
        let output = commandOutput(executable: executable, arguments: ["-version"])
        let version = firstCapture(pattern: #"Apache Maven\s+([^\s]+)"#, in: output) ?? ""
        let home = executable.deletingLastPathComponent().deletingLastPathComponent().path
        return MavenRuntimeCandidate(homePath: home, executablePath: executable.path, version: version)
    }

    private static func javaHomeOutput() -> [String] {
        let output = commandOutput(
            executable: URL(fileURLWithPath: "/usr/libexec/java_home"),
            arguments: ["-V"]
        )
        return output
            .split(separator: "\n")
            .compactMap { line in
                firstCapture(pattern: #"(\/[^\s]+\/Contents\/Home)"#, in: String(line))
            }
    }

    fileprivate static func systemMavenExecutable(environment: [String: String]) -> URL? {
        discoverMavenExecutables(environment: environment).first
    }

    fileprivate static func mavenExecutable(forHomePath path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let candidates = [
            url,
            url.appendingPathComponent("bin/mvn")
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private static func validJavaHome(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/java").path)
            ? url
            : nil
    }

    private static func directoryNames(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    private static func commandOutput(executable: URL, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private static func firstCapture(pattern: String, in input: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: input,
                  range: NSRange(input.startIndex..<input.endIndex, in: input)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: input) else { return nil }
        return String(input[range])
    }
}
