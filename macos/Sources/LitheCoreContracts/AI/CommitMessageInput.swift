import Foundation

public enum CommitMessageChangeKind: String, Sendable {
    case added, modified, deleted, renamed, copied, unmerged, untracked
    public var title: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .unmerged: "Unmerged"
        case .untracked: "Untracked"
        }
    }
}

public struct CommitMessageFileInput: Sendable {
    public let path: String
    public let changeKind: CommitMessageChangeKind
    public let diff: String
    public init(path: String, changeKind: CommitMessageChangeKind, diff: String) {
        self.path = path; self.changeKind = changeKind; self.diff = diff
    }
}

public struct CommitMessageInput: Sendable {
    public let files: [CommitMessageFileInput]
    public init(files: [CommitMessageFileInput]) { self.files = files }
    public init(path: String, changeKind: CommitMessageChangeKind, diff: String) {
        files = [CommitMessageFileInput(path: path, changeKind: changeKind, diff: diff)]
    }
    public var path: String { files.count == 1 ? (files.first?.path ?? "") : "\(files.count) files" }
    public var changeKind: CommitMessageChangeKind { files.count == 1 ? (files.first?.changeKind ?? .modified) : .modified }
    public var diff: String { files.map(\.diff).joined(separator: "\n\n") }
}
