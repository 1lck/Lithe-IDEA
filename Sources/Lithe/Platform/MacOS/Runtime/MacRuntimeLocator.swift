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

    func isExecutable(at url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    func systemMavenExecutable() -> URL? {
        MacRuntimeDiscovery.systemMavenExecutable(environment: environment())
    }

    func mavenExecutable(forHomePath path: String) -> URL? {
        MacRuntimeDiscovery.mavenExecutable(forHomePath: path)
    }

    func systemJDBExecutable() -> URL? {
        MacRuntimeDiscovery.systemJDBExecutable()
    }

    func javaLanguageServerExecutable() -> URL? {
        MacRuntimeDiscovery.javaLanguageServerExecutable()
    }
}
