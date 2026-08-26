import Foundation

package protocol BuiltinLanguageFeatureCore: Sendable {
    var isBuiltinLanguageFeatureAvailable: Bool { get }
    func builtinLanguageCompletions(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> [LanguageServerCompletionItem]?
    func builtinLanguageHover(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> LanguageServerHover?
    func builtinLanguageNavigation(
        method: String,
        fileURL: URL,
        text: String,
        position: LanguageServerPosition
    ) -> [LanguageServerLocation]?
}
