import Foundation

package enum GitWorktreeMode: String, Codable, CaseIterable, Sendable {
    case newBranch, existingBranch, detached
}

package struct GitWorktreeCreation: Sendable {
    package let mode: GitWorktreeMode
    package let name: String?
    package let reference: GitReference?
    package let revision: String?
    package let destination: URL
    package let noCheckout: Bool

    package init(mode: GitWorktreeMode, name: String?, reference: GitReference?, revision: String?, destination: URL, noCheckout: Bool) {
        self.mode = mode
        self.name = name
        self.reference = reference
        self.revision = revision
        self.destination = destination
        self.noCheckout = noCheckout
    }
}
