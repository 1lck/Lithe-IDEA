import Foundation

package struct GitWorkspaceStatusOutcome: Encodable, Sendable {
    package let root: String
    package let success: Bool
    package init(root: String, success: Bool) { self.root = root; self.success = success }
}

package struct GitWorkspaceStatusPlan: Decodable, Sendable {
    package struct Entry: Decodable, Sendable {
        package let root: String
        package let source: String
        package init(root: String, source: String) { self.root = root; self.source = source }
    }
    package let entries: [Entry]
    package let confirmedRoots: [String]
    package let failedRoots: [String]
    package init(entries: [Entry], confirmedRoots: [String], failedRoots: [String]) {
        self.entries = entries; self.confirmedRoots = confirmedRoots; self.failedRoots = failedRoots
    }
}
