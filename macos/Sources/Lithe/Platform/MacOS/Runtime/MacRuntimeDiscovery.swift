import Foundation

enum MacRuntimeDiscovery {
    private static let probeCache = MacRuntimeProbeCache()
    /// Filled by background discovery. Selection paths run on the main actor
    /// and only read it, so they never start a login shell or `java_home`.
    static let shellEnvironmentCache = MacShellEnvironmentCache()
    private static let loginShellEnvironmentTimeoutMilliseconds = 1_500
    private static let loginShellEnvironmentMarker = "__LITHE_LOGIN_SHELL_ENVIRONMENT__"
    private static let loginShellEnvironmentByteLimit = 256 * 1_024
    private static let loginShellEnvironmentVariableLimit = 1_024
    /// Version managers keep one directory per installed version; a root
    /// with more entries than this is not a version list and is truncated.
    static let managedInstallationEntryLimit = 256

    static func invalidateProbeCaches() { probeCache.invalidate() }

    static func discover(environment: [String: String]) -> RuntimeDiscoveryResult {
        let enrichedEnvironment = enrichedEnvironment(environment)
        let javaRuntimes = javaRuntimes(enrichedEnvironment: enrichedEnvironment, isCancelled: { false })
        let mavenRuntimes = discoverMavenExecutables(environment: enrichedEnvironment)
            .compactMap { probeMaven($0, environment: enrichedEnvironment) }
            .sorted { lhs, rhs in
                lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
            }
        return RuntimeDiscoveryResult(javaRuntimes: javaRuntimes, mavenRuntimes: mavenRuntimes)
    }

    static func systemMavenExecutable(environment: [String: String]) -> URL? {
        discoverMavenExecutables(environment: cachedEnrichedEnvironment(environment)).first
    }

    static func mavenExecutable(forHomePath path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        let candidates: [URL]
        if isDirectory.boolValue {
            // A daemon distribution must launch its client, not its embedded Maven.
            candidates = [url.appendingPathComponent("bin"), url].flatMap { bin in
                ["mvnd", "mvn"].map { bin.appendingPathComponent($0) }
            }
        } else {
            candidates = [url]
        }
        return candidates.first { MacRuntimeLocator().isExecutable(at: $0) }
    }

    static func validJavaHome(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/java").path)
            ? url
            : nil
    }

    static func discoverJavaRuntimes(
        environment: [String: String], isCancelled: @Sendable () -> Bool = { false }
    ) -> [JavaRuntimeCandidate] {
        guard !isCancelled() else { return [] }
        return javaRuntimes(enrichedEnvironment: enrichedEnvironment(environment), isCancelled: isCancelled)
    }

    private static func javaRuntimes(
        enrichedEnvironment: [String: String], isCancelled: () -> Bool
    ) -> [JavaRuntimeCandidate] {
        shellEnvironmentCache.storeSystemJavaHome(systemLauncherJavaHome())
        let homes = discoverJavaHomes(environment: enrichedEnvironment)
        var runtimes: [JavaRuntimeCandidate] = []
        for home in homes {
            guard !isCancelled() else { return [] }
            if let runtime = probeJavaHome(home) { runtimes.append(runtime) }
        }
        return runtimes.sorted { lhs, rhs in
            lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
        }
    }

    static func javaHomeOnPath(environment: [String: String]) -> URL? {
        javaHomeOnPath(
            in: cachedEnrichedEnvironment(environment),
            systemJavaHome: { shellEnvironmentCache.systemJavaHome() }
        )
    }

    static func javaHomeOnPath(
        in environment: [String: String], systemJavaHome: () -> String?
    ) -> URL? {
        var foundSystemLauncher = false
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let executable = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("java")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            let resolved = executable.resolvingSymlinksInPath()
            // Apple's system launcher selects a JDK itself; /usr is not a JDK
            // home and must never become JAVA_HOME for child processes. A GUI
            // launch puts /usr/bin before the login shell's PATH, so keep
            // scanning for a real JDK and only then use the launcher's choice.
            if resolved.path == "/usr/bin/java" {
                foundSystemLauncher = true
                continue
            }
            if let home = validJavaHome(resolved.deletingLastPathComponent().deletingLastPathComponent().path) {
                return home
            }
        }
        return foundSystemLauncher ? systemJavaHome().flatMap(validJavaHome) : nil
    }

    private static func discoverJavaHomes(environment: [String: String]) -> [URL] {
        discoverJavaHomes(
            environment: environment,
            homeDirectory: NSHomeDirectory(),
            javaHomePaths: javaHomeOutput(),
            directoryEntries: directoryNames(at:),
            managedDirectoryEntries: { boundedDirectoryNames(at: $0, limit: managedInstallationEntryLimit) }
        )
    }

    static func discoverJavaHomes(
        environment: [String: String],
        homeDirectory: String,
        javaHomePaths: [String],
        directoryEntries: (String) -> [String],
        managedDirectoryEntries: ((String) -> [String])? = nil
    ) -> [URL] {
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
        add(javaHomeOnPath(in: environment, systemJavaHome: { nil })?.path)
        for path in javaHomePaths {
            add(path)
        }

        for root in [
            "/Library/Java/JavaVirtualMachines",
            homeDirectory + "/Library/Java/JavaVirtualMachines"
        ] {
            for entry in directoryEntries(root).sorted() {
                add(root + "/" + entry + "/Contents/Home")
            }
        }

        for root in ["/opt/homebrew/opt", "/usr/local/opt"] {
            for entry in directoryEntries(root).sorted() where entry.hasPrefix("openjdk") {
                add(root + "/" + entry + "/libexec/openjdk.jdk/Contents/Home")
            }
        }

        for root in managedInstallationRoots(
            candidate: "java", environment: environment, homeDirectory: homeDirectory
        ) {
            let entries = managedDirectoryEntries.map { $0(root) } ?? directoryEntries(root)
            for entry in entries.prefix(managedInstallationEntryLimit).sorted() {
                add(root + "/" + entry)
            }
        }

        return paths.values.sorted { $0.path < $1.path }
    }

    static func discoverMavenExecutables(
        environment: [String: String],
        isExecutable: (URL) -> Bool = { MacRuntimeLocator().isExecutable(at: $0) }
    ) -> [URL] {
        var paths: [URL] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard isExecutable(url) else { return }
            let identity = url.resolvingSymlinksInPath().path
            guard seen.insert(identity).inserted else { return }
            paths.append(url)
        }

        for key in ["MAVEN_HOME", "M2_HOME"] {
            if let home = environment[key], !home.isEmpty {
                add(URL(fileURLWithPath: home).appendingPathComponent("bin/mvn").path)
            }
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in pathDirectories {
            add(URL(fileURLWithPath: directory).appendingPathComponent("mvn").path)
        }
        for root in managedInstallationRoots(
            candidate: "maven", environment: environment, homeDirectory: NSHomeDirectory()
        ) {
            for entry in boundedDirectoryNames(at: root, limit: managedInstallationEntryLimit).sorted() {
                add(URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(entry, isDirectory: true)
                    .appendingPathComponent("bin/mvn").path)
            }
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
        // Preserve ordinary Maven preference even when mvnd appears earlier on PATH.
        // Discovery only inspects files; importing Java must not start a daemon.
        if let home = environment["MVND_HOME"], !home.isEmpty {
            add(URL(fileURLWithPath: home).appendingPathComponent("bin/mvnd").path)
        }
        for directory in pathDirectories {
            add(URL(fileURLWithPath: directory).appendingPathComponent("mvnd").path)
        }
        for path in [
            "/opt/homebrew/opt/mvnd/bin/mvnd",
            "/opt/homebrew/bin/mvnd",
            "/usr/local/opt/mvnd/bin/mvnd",
            "/usr/local/bin/mvnd"
        ] {
            add(path)
        }
        return paths
    }

    static func probeJavaHome(_ home: URL) -> JavaRuntimeCandidate? {
        let output = cachedCommandOutput(
            executable: home.appendingPathComponent("bin/java"),
            arguments: ["-version"], dependencies: [home.appendingPathComponent("release")],
            accepts: { firstCapture(pattern: #"version\s+\"([^\"]+)\""#, in: $0) != nil }
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

    /// `environment` is the one Maven was found with; a launcher that relies
    /// on the login shell's JAVA_HOME or PATH fails without it.
    static func probeMaven(_ executable: URL, environment: [String: String]? = nil) -> MavenRuntimeCandidate? {
        let resolvedExecutable = executable.resolvingSymlinksInPath()
        let distribution = resolvedExecutable.deletingLastPathComponent().deletingLastPathComponent()
        let homeURL = resolvedExecutable.lastPathComponent == "mvnd"
            ? distribution.appendingPathComponent("mvn") : distribution
        let library = homeURL.appendingPathComponent("lib")
        let libraries = directoryNames(at: library.path).filter { $0.hasPrefix("maven-core-") }.sorted()
        let wrapper = resolvedExecutable.deletingLastPathComponent().appendingPathComponent(".mvn/wrapper")
        let output = cachedCommandOutput(
            executable: executable, arguments: ["-version"], environment: environment,
            dependencies: [library] + libraries.map { library.appendingPathComponent($0) }
                + [wrapper.appendingPathComponent("maven-wrapper.properties"), wrapper.appendingPathComponent("maven-wrapper.jar")],
            accepts: { mavenVersion(in: $0) != nil }
        )
        guard let version = mavenVersion(in: output) else { return nil }
        return MavenRuntimeCandidate(homePath: distribution.path, executablePath: executable.path, version: version)
    }

    static func mavenVersion(in output: String) -> String? {
        // mvnd prints its own banner before the embedded Apache Maven version.
        firstCapture(pattern: #"Apache Maven\s+([0-9][^\s\x1B]*)"#, in: output)
    }

    private static func javaHomeOutput() -> [String] {
        let roots = ["/Library/Java/JavaVirtualMachines", NSHomeDirectory() + "/Library/Java/JavaVirtualMachines"]
        let dependencies = roots.flatMap { root in
            [URL(fileURLWithPath: root)] + directoryNames(at: root).sorted().map {
                URL(fileURLWithPath: root).appendingPathComponent($0)
            }
        }
        let output = cachedCommandOutput(
            executable: URL(fileURLWithPath: "/usr/libexec/java_home"),
            arguments: ["-V"], dependencies: dependencies, accepts: { _ in true }
        )
        return output
            .split(separator: "\n")
            .compactMap { line in
                firstCapture(pattern: #"(\/[^\s]+\/Contents\/Home)"#, in: String(line))
            }
    }

    /// The JDK that `/usr/bin/java` launches. The probe cache keys on the
    /// executable rather than its arguments, so this bypasses the cache that
    /// already holds the `java_home -V` listing.
    private static func systemLauncherJavaHome() -> String? {
        let result = MacProcessRunner().run(ProcessRequest(
            executablePath: "/usr/libexec/java_home", timeoutMilliseconds: 5_000
        ))
        guard result.succeeded else { return nil }
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
    }

    /// Starts a login shell; call only from background discovery.
    private static func enrichedEnvironment(_ environment: [String: String]) -> [String: String] {
        let shellEnvironment = loginShellEnvironment(environment)
        shellEnvironmentCache.store(shellEnvironment, for: environment)
        return mergeEnvironment(environment, shellEnvironment: shellEnvironment)
    }

    /// The last background discovery's login shell environment merged into
    /// `environment`, or `environment` alone before discovery has run.
    static func cachedEnrichedEnvironment(_ environment: [String: String]) -> [String: String] {
        guard let shellEnvironment = shellEnvironmentCache.shellEnvironment(for: environment) else {
            return environment
        }
        return mergeEnvironment(environment, shellEnvironment: shellEnvironment)
    }

    static func mergeEnvironment(
        _ environment: [String: String], shellEnvironment: [String: String]
    ) -> [String: String] {
        var merged = environment
        for (key, value) in shellEnvironment where key != "PATH" {
            if merged[key]?.isEmpty != false { merged[key] = value }
        }
        let inheritedPath = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let shellPath = shellEnvironment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var paths = Set<String>()
        merged["PATH"] = (inheritedPath + shellPath).filter { paths.insert($0).inserted }.joined(separator: ":")
        return merged
    }

    private static func loginShellEnvironment(_ environment: [String: String]) -> [String: String] {
        let shell = environment["SHELL"].flatMap { path in
            path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
        } ?? "/bin/zsh"
        // Startup files may print to stderr, which the runner merges into the
        // output, so the environment follows a marker. head caps the capture
        // one byte past the limit so an oversized environment is detectable.
        let result = MacProcessRunner().run(ProcessRequest(
            executablePath: shell,
            arguments: [
                "-ilc",
                "printf '\\0%s\\0' \(loginShellEnvironmentMarker); env -0 | head -c \(loginShellEnvironmentByteLimit + 1)"
            ],
            environment: environment,
            timeoutMilliseconds: loginShellEnvironmentTimeoutMilliseconds
        ))
        guard result.succeeded else { return [:] }
        return parseLoginShellEnvironment(result.output)
    }

    /// Reads `env -0` records after the marker. Output without the marker, or
    /// larger than the byte or variable limit, is ignored as a whole so a
    /// truncated PATH can never replace the inherited one.
    static func parseLoginShellEnvironment(_ output: String) -> [String: String] {
        guard let markerRange = output.range(of: "\0" + loginShellEnvironmentMarker + "\0", options: .backwards) else {
            return [:]
        }
        let records = output[markerRange.upperBound...]
        guard records.utf8.count <= loginShellEnvironmentByteLimit else { return [:] }
        let items = records.split(separator: "\0")
        guard items.count <= loginShellEnvironmentVariableLimit else { return [:] }
        return items.reduce(into: [String: String]()) { values, item in
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                  parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return }
            values[String(parts[0])] = String(parts[1])
        }
    }

    private static func managedInstallationRoots(
        candidate: String, environment: [String: String], homeDirectory: String
    ) -> [String] {
        let miseData = environment["MISE_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory + "/.local/share/mise"
        let asdfData = environment["ASDF_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory + "/.asdf"
        let sdkmanData = environment["SDKMAN_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory + "/.sdkman"
        return [
            miseData + "/installs/" + candidate,
            asdfData + "/installs/" + candidate,
            sdkmanData + "/candidates/" + candidate
        ].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
    }

    private static func directoryNames(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// Reads at most `limit` entries instead of loading a whole directory.
    static func boundedDirectoryNames(at path: String, limit: Int) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return [] }
        var names: [String] = []
        while names.count < limit, let url = enumerator.nextObject() as? URL {
            names.append(url.lastPathComponent)
        }
        return names
    }

    private static func cachedCommandOutput(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        dependencies: [URL], accepts: (String) -> Bool
    ) -> String {
        let key = MacRuntimeProbeCache.key(
            executable: executable, dependencies: dependencies, environment: environment
        )
        return probeCache.value(for: key) {
            let result = MacProcessRunner().run(ProcessRequest(
                executablePath: executable.path, arguments: arguments,
                environment: environment, timeoutMilliseconds: 5_000
            ))
            return result.succeeded && accepts(result.output) ? result.output : nil
        } ?? ""
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
