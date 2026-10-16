import Foundation

enum MacRuntimeDiscovery {
    private static let probeCache = MacRuntimeProbeCache()

    static func invalidateProbeCaches() { probeCache.invalidate() }

    static func discover(environment: [String: String]) -> RuntimeDiscoveryResult {
        let javaRuntimes = discoverJavaRuntimes(environment: environment)
        let mavenRuntimes = discoverMavenExecutables(environment: environment)
            .compactMap(probeMaven)
            .sorted { lhs, rhs in
                lhs.version.localizedStandardCompare(rhs.version) == .orderedDescending
            }
        return RuntimeDiscoveryResult(javaRuntimes: javaRuntimes, mavenRuntimes: mavenRuntimes)
    }

    static func systemMavenExecutable(environment: [String: String]) -> URL? {
        discoverMavenExecutables(environment: environment).first
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
        let homes = discoverJavaHomes(environment: environment)
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
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let executable = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("java")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
            let resolved = executable.resolvingSymlinksInPath()
            // Apple's system launcher selects a JDK itself; /usr is not a JDK
            // home and must never become JAVA_HOME for child processes.
            guard resolved.path != "/usr/bin/java" else { return nil }
            return validJavaHome(resolved.deletingLastPathComponent().deletingLastPathComponent().path)
        }
        return nil
    }

    private static func discoverJavaHomes(environment: [String: String]) -> [URL] {
        discoverJavaHomes(
            environment: environment,
            homeDirectory: NSHomeDirectory(),
            javaHomePaths: javaHomeOutput(),
            directoryEntries: directoryNames(at:)
        )
    }

    static func discoverJavaHomes(
        environment: [String: String],
        homeDirectory: String,
        javaHomePaths: [String],
        directoryEntries: (String) -> [String]
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

        let sdkmanRoot = environment["SDKMAN_DIR"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? homeDirectory + "/.sdkman"
        let sdkmanJavaRoot = URL(fileURLWithPath: sdkmanRoot, isDirectory: true)
            .appendingPathComponent("candidates/java", isDirectory: true)
            .standardizedFileURL.path
        for entry in directoryEntries(sdkmanJavaRoot).sorted() {
            add(sdkmanJavaRoot + "/" + entry)
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
            guard isExecutable(url), seen.insert(url.path).inserted else { return }
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

    static func probeMaven(_ executable: URL) -> MavenRuntimeCandidate? {
        let resolvedExecutable = executable.resolvingSymlinksInPath()
        let distribution = resolvedExecutable.deletingLastPathComponent().deletingLastPathComponent()
        let homeURL = resolvedExecutable.lastPathComponent == "mvnd"
            ? distribution.appendingPathComponent("mvn") : distribution
        let library = homeURL.appendingPathComponent("lib")
        let libraries = directoryNames(at: library.path).filter { $0.hasPrefix("maven-core-") }.sorted()
        let wrapper = resolvedExecutable.deletingLastPathComponent().appendingPathComponent(".mvn/wrapper")
        let output = cachedCommandOutput(
            executable: executable, arguments: ["-version"],
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

    private static func directoryNames(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    private static func cachedCommandOutput(
        executable: URL, arguments: [String], dependencies: [URL], accepts: (String) -> Bool
    ) -> String {
        probeCache.value(for: MacRuntimeProbeCache.key(executable: executable, dependencies: dependencies)) {
            let result = MacProcessRunner().run(ProcessRequest(
                executablePath: executable.path, arguments: arguments, timeoutMilliseconds: 5_000
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
