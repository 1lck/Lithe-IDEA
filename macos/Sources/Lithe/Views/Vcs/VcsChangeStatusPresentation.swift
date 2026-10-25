import LitheModuleAPI
import LitheCoreContracts
import SwiftUI

// Note: 统一 VCS 模型见 .agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md

/// How plugin VCS statuses look in the tool window and the project tree.
/// Letters follow the command-line clients most users know; colors follow
/// IDEA's file status colors, as the Git views do.
extension VcsChangeStatus {
    var letter: String {
        switch self {
        case .modified: "M"
        case .added, .copied: "A"
        case .deleted: "D"
        case .missing: "!"
        case .renamed, .replaced: "R"
        case .typeChanged: "T"
        case .unversioned: "?"
        case .ignored: "I"
        case .conflicted: "C"
        case .switched: "S"
        }
    }

    var title: String {
        switch self {
        case .modified: L10n.string("Modified")
        case .added: L10n.string("Added")
        case .copied: L10n.string("Copied")
        case .deleted: L10n.string("Deleted")
        case .missing: L10n.string("Missing")
        case .renamed: L10n.string("Moved")
        case .replaced: L10n.string("Replaced")
        case .typeChanged: L10n.string("Type changed")
        case .unversioned: L10n.string("Unversioned")
        case .ignored: L10n.string("Ignored")
        case .conflicted: L10n.string("Conflicted")
        case .switched: L10n.string("Switched")
        }
    }

    /// File name color in change lists.
    var listColor: Color {
        switch self {
        case .modified, .typeChanged, .switched, .replaced: LitheTheme.Commit.fileModified
        case .added, .copied: LitheTheme.Commit.fileAdded
        case .deleted, .missing: LitheTheme.Commit.fileDeleted
        case .renamed: LitheTheme.Commit.fileRenamed
        case .unversioned: LitheTheme.Commit.fileUntracked
        case .ignored: LitheTheme.Commit.fileIgnored
        case .conflicted: LitheTheme.Commit.fileConflicted
        }
    }

    /// Row color in the project tree, matching its Git colors.
    var treeColor: Color {
        switch self {
        case .modified, .typeChanged, .switched, .replaced: LitheTheme.accent
        case .added, .copied: LitheTheme.success
        case .deleted, .missing: LitheTheme.error
        case .renamed: LitheTheme.skill
        case .unversioned: LitheTheme.Commit.fileUntracked
        case .ignored: LitheTheme.Commit.fileIgnored
        case .conflicted: LitheTheme.warning
        }
    }
}
