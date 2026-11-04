import Foundation
import LitheModuleAPI

/// Result of Core's `git.branchNamePreview`.
///
/// Core owns IDEA's `GitRefNameValidator` cleanup and conflict rules so both
/// platforms create identically named branches; the new-branch dialog only
/// renders this result and submits `cleanedName`.
package struct GitBranchNamePreview: Equatable, Sendable {
    /// Name cleaned while typing: illegal characters dropped and spaces or
    /// control characters replaced with the cleanup symbol.
    package let typingCleanedName: String
    /// Name cleaned for submission: `typingCleanedName` without a trailing
    /// `.`, `/` or `.lock`.
    package let cleanedName: String
    /// IDEA's suggested name for the reference the dialog was opened from; a
    /// remote reference loses its remote prefix.
    package let initialName: String
    /// `nil` when the name can be created.
    package let error: GitBranchNameError?

    package init(
        typingCleanedName: String,
        cleanedName: String,
        initialName: String,
        error: GitBranchNameError?
    ) {
        self.typingCleanedName = typingCleanedName
        self.cleanedName = cleanedName
        self.initialName = initialName
        self.error = error
    }
}

/// Stable Core codes for a rejected new branch name, in IDEA's check order.
package enum GitBranchNameErrorCode: String, Codable, Sendable {
    case empty
    case head
    case clashesWithRemote
    case clashesWithDirectory
    case alreadyExists
    case clashesWithBranchPrefix
}

package struct GitBranchNameError: Equatable, Sendable {
    package let code: GitBranchNameErrorCode
    /// Conflicting remote branch, local branch or local branch directory.
    package let name: String?
    /// Existing local branch occupying one of the proposed name's `/` prefixes.
    package let branch: String?

    package init(code: GitBranchNameErrorCode, name: String? = nil, branch: String? = nil) {
        self.code = code
        self.name = name
        self.branch = branch
    }
}

package extension GitBranchNameError {
    /// Shared i18n entry and its ordered arguments for the inline validation
    /// copy. The shared entries declare `name` before `branch`, so this order
    /// must stay aligned with the locale files.
    var localization: (key: String, arguments: [String]) {
        switch code {
        case .empty:
            ("git.log.branchNameEmpty", [])
        case .head:
            ("git.log.branchNameHead", [])
        case .clashesWithRemote:
            ("git.log.branchNameClashesWithRemote", [name ?? ""])
        case .clashesWithDirectory:
            ("git.log.branchNameClashesWithDirectory", [name ?? ""])
        case .alreadyExists:
            ("git.log.branchNameAlreadyExists", [name ?? ""])
        case .clashesWithBranchPrefix:
            ("git.log.branchNameClashesWithBranchPrefix", [name ?? "", branch ?? ""])
        }
    }

    /// Inline validation copy resolved through the application language.
    var localizedMessage: String {
        let localization = localization
        guard !localization.arguments.isEmpty else { return L10n.string(key: localization.key) }
        return String(
            format: L10n.string(key: localization.key),
            arguments: localization.arguments.map { $0 as CVarArg }
        )
    }
}
