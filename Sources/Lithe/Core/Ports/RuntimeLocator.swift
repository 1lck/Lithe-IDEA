import Foundation

protocol RuntimeLocator: Sendable {
    func environment() -> [String: String]
    func discover() -> RuntimeDiscoveryResult
    func validJavaHome(path: String) -> URL?
    func isExecutable(at url: URL) -> Bool
    func systemMavenExecutable() -> URL?
    func mavenExecutable(forHomePath path: String) -> URL?
    func systemJDBExecutable() -> URL?
    func javaLanguageServerExecutable() -> URL?
}
