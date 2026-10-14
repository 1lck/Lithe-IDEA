import Foundation

@MainActor
package protocol LanguageToolRuntimePort: AnyObject {
    func executableOnPath(_ name: String) -> URL?
    func executableURL(at path: String) -> URL?
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate]
    /// Environment for a language-server process. Each runtime tool is
    /// discovered, exported as `LITHE_<TOOL>_PATH`, and put on `PATH`.
    func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String]
    func missingLanguageToolMessage(_ name: String) -> String
}

extension LanguageToolRuntimePort {
    package func languageToolProcessEnvironment() -> [String: String] {
        languageToolProcessEnvironment(runtimeTools: [])
    }
}
