import Foundation

enum MacRuntimeDiscovery {
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

    static func systemMavenExecutable(environment: [String: String]) -> URL? {
        discoverMavenExecutables(environment: environment).first
    }

    static func mavenExecutable(forHomePath path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let candidates = [
            url,
            url.appendingPathComponent("bin/mvn")
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    static func validJavaHome(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("bin/java").path)
            ? url
            : nil
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

    static func probeJavaHome(_ home: URL) -> JavaRuntimeCandidate? {
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

    static func probeMaven(_ executable: URL) -> MavenRuntimeCandidate? {
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

    private static func directoryNames(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    private static func commandOutput(executable: URL, arguments: [String]) -> String {
        MacProcessRunner().run(ProcessRequest(
            executablePath: executable.path,
            arguments: arguments,
            timeoutMilliseconds: 5_000
        )).output
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
