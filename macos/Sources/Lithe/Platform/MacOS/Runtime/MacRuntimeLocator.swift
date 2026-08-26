import Foundation

struct MacRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    func discover() -> RuntimeDiscoveryResult {
        MacRuntimeDiscovery.discover(environment: environment())
    }

    func validJavaHome(path: String) -> URL? {
        MacRuntimeDiscovery.validJavaHome(path)
    }

    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        MacRuntimeDiscovery.probeJavaHome(homeURL)
    }

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func systemMavenExecutable() -> URL? {
        MacRuntimeDiscovery.systemMavenExecutable(environment: environment())
    }

    func mavenExecutable(forHomePath path: String) -> URL? {
        MacRuntimeDiscovery.mavenExecutable(forHomePath: path)
    }

    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? {
        MacRuntimeDiscovery.probeMaven(executableURL)
    }

    func systemJDBExecutable() -> URL? {
        MacRuntimeDiscovery.systemJDBExecutable()
    }

    /// Returns the home directory of the JDK bundled under the app's
    /// `Contents/Resources/LanguageServers/jdk` directory, if present and
    /// executable.  Development builds that lack the bundled JDK return `nil`
    /// so the caller can fall back to user-discovered runtimes.
    func bundledJdkHome() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let home = resourceURL
            .appendingPathComponent("LanguageServers")
            .appendingPathComponent("jdk")
            .standardizedFileURL
        let java = home.appendingPathComponent("bin/java")
        guard FileManager.default.isExecutableFile(atPath: java.path) else { return nil }
        return home
    }
}
