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

    func javaLanguageServerExecutable() -> URL? {
        MacRuntimeDiscovery.javaLanguageServerExecutable()
    }
}
