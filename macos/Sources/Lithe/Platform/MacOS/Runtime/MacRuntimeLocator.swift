import Foundation

struct MacRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    func discover() -> RuntimeDiscoveryResult {
        MacRuntimeDiscovery.discover(environment: environment())
    }

    func discoverJavaRuntimes() -> [JavaRuntimeCandidate] {
        MacRuntimeDiscovery.discoverJavaRuntimes(environment: environment())
    }

    func discoverJavaRuntimes(isCancelled: @Sendable () -> Bool) -> [JavaRuntimeCandidate] {
        MacRuntimeDiscovery.discoverJavaRuntimes(environment: environment(), isCancelled: isCancelled)
    }

    func invalidateProbeCache() { MacRuntimeDiscovery.invalidateProbeCaches() }

    func validJavaHome(path: String) -> URL? {
        MacRuntimeDiscovery.validJavaHome(path)
    }

    func javaHomeOnPath(in candidates: [JavaRuntimeCandidate]) -> URL? {
        guard let home = MacRuntimeDiscovery.javaHomeOnPath(environment: environment()) else { return nil }
        return candidates.lazy.compactMap { candidate -> URL? in
            let url = URL(fileURLWithPath: candidate.homePath, isDirectory: true)
            return url.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path ? url : nil
        }.first
    }

    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? {
        MacRuntimeDiscovery.probeJavaHome(homeURL)
    }

    func isExecutable(at url: URL) -> Bool {
        // Directory execute permission allows traversal, not process launch.
        // Follow symlinks so linked toolchain homes are rejected as well.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
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
}
