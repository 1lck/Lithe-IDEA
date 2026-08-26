import Foundation

@MainActor
package protocol LanguageToolRuntimePort: AnyObject {
    func executableOnPath(_ name: String) -> URL?
    func executableURL(at path: String) -> URL?
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate]
    func languageToolProcessEnvironment() -> [String: String]
    func missingLanguageToolMessage(_ name: String) -> String
}
