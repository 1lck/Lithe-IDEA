import Foundation

package enum GitIdentityScope: String, Codable, CaseIterable, Sendable {
    case local, global
}

package enum GitIdentityField: String, Codable, Sendable {
    case name, email
}

package struct GitRepositorySetup: Codable, Equatable, Sendable {
    package let isRepository: Bool
    package let hasCommits: Bool
    package let branch: String?
    package let scope: GitIdentityScope
    package let configuredName: String?
    package let configuredEmail: String?
    package let effectiveName: String?
    package let effectiveEmail: String?

    package var needsIdentity: Bool {
        (effectiveName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (effectiveEmail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

package struct GitSetupFailure: Error, Sendable {
    package let message: String
    package init(_ message: String) { self.message = message }
}
