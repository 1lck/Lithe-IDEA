import LitheModuleAPI
import Foundation

enum LanguageServerTextEditApplicator {
    enum Error: LocalizedError, Equatable {
        case invalidRange
        case overlappingEdits

        var errorDescription: String? {
            switch self {
            case .invalidRange: L10n.string("Language server returned an invalid text range.")
            case .overlappingEdits: L10n.string("Language server returned overlapping text edits.")
            }
        }
    }

    /// Core owns range validation, line counting, ordering and overlap rules,
    /// shared with plugin document edits (`editor.planTextEdits`).
    static func apply(_ edits: [LanguageServerTextEdit], to text: String) throws -> String {
        switch RustCoreBridge().applyLanguageServerTextEdits(edits, to: text) {
        case .success(let payload):
            return payload.text
        case .failure(let error):
            switch error.details {
            case "overlappingEdits": throw Error.overlappingEdits
            default: throw Error.invalidRange
            }
        }
    }
}

enum LanguageServerSnippet {
    static func plainText(_ value: String) -> String {
        if let text = RustCoreBridge().plainLanguageServerSnippet(value) {
            return text
        }
        var result = value
        if let placeholders = try? NSRegularExpression(pattern: #"\$\{\d+:([^}]*)\}"#) {
            result = placeholders.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: "$1"
            )
        }
        if let tabStops = try? NSRegularExpression(pattern: #"\$\{?\d+\}?"#) {
            result = tabStops.stringByReplacingMatches(
                in: result,
                range: NSRange(location: 0, length: (result as NSString).length),
                withTemplate: ""
            )
        }
        return result
    }
}
