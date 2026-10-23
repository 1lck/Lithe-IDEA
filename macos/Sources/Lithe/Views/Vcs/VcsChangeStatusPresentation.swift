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
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .copied: String(localized: "Copied")
        case .deleted: String(localized: "Deleted")
        case .missing: String(localized: "Missing")
        case .renamed: String(localized: "Moved")
        case .replaced: String(localized: "Replaced")
        case .typeChanged: String(localized: "Type changed")
        case .unversioned: String(localized: "Unversioned")
        case .ignored: String(localized: "Ignored")
        case .conflicted: String(localized: "Conflicted")
        case .switched: String(localized: "Switched")
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
