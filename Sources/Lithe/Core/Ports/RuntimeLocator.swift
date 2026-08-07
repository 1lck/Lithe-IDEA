import Foundation

protocol RuntimeLocator: Sendable {
    func environment() -> [String: String]
    func discover() -> RuntimeDiscoveryResult
    func validJavaHome(path: String) -> URL?
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate?
    func isExecutable(at url: URL) -> Bool
    func systemMavenExecutable() -> URL?
    func mavenExecutable(forHomePath path: String) -> URL?
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate?
    func systemJDBExecutable() -> URL?
    func javaLanguageServerExecutable() -> URL?
}
