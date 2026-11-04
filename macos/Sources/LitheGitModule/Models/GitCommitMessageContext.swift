import Foundation
import LitheCoreContracts

package struct GitCommitMessageSelectedFile: Codable, Sendable {
    package let path: String
    package let originalPath: String?
    package let changeKind: String
    package init(path: String, originalPath: String?, changeKind: String) {
        self.path = path; self.originalPath = originalPath; self.changeKind = changeKind
    }
}

package struct GitCommitMessageRepository: Codable, Sendable {
    package let root: String
    package let files: [GitCommitMessageSelectedFile]
    package init(root: String, files: [GitCommitMessageSelectedFile]) { self.root = root; self.files = files }
}

package struct GitCommitMessageCoreFile: Decodable, Sendable {
    package let path: String
    package let changeKind: String
    package let diff: String
    package let originalCharacters: Int
    package let truncated: Bool
}

package struct GitCommitMessageCoreCapture: Decodable, Sendable {
    package let files: [GitCommitMessageCoreFile]
    package let token: String
}

package struct GitCommitMessageContext: Sendable {
    package let input: CommitMessageInput
    package let token: String
    package let repositories: [GitCommitMessageRepository]
    package init(input: CommitMessageInput, token: String, repositories: [GitCommitMessageRepository]) {
        self.input = input; self.token = token; self.repositories = repositories
    }
}
