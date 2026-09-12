import Foundation

package struct GitExecutionOptions: Codable, Equatable, Sendable {
    package var executable: String?
    package var interactive = false
    package var useCredentialHelper = true
    package var fetchDefaults = GitFetchOptions()
    package var detailedFetch = true
    package init() {}
}

/// The composition root shares this snapshot with background Git readers without actor hops.
package final class GitExecutionPreferences: @unchecked Sendable {
    private let lock = NSLock()
    private var options = GitExecutionOptions()
    package init() {}
    package func update(_ value: GitExecutionOptions) { lock.withLock { options = value } }
    package var snapshot: GitExecutionOptions { lock.withLock { options } }
}

package struct GitConfigurationEntry: Decodable, Identifiable, Sendable {
    package let key: String
    package let value: String
    package let scope: String
    package let origin: String
    package let effective: Bool
    package var id: String { "\(scope)|\(origin)|\(key)|\(value)" }
}
package struct GitConfigurationField: Decodable, Identifiable, Sendable {
    package let key: String
    package let choices: [String]
    package let configuredValues: [String]
    package var id: String { key }
}
package struct GitExecutionSettingsSnapshot: Decodable, Sendable {
    package let executable: String?
    package let version: String
    package let scope: String
    package let entries: [GitConfigurationEntry]
    package let fields: [GitConfigurationField]
    package let temporaryConfig: [[String]]
    package var fetchSources: [String: GitConfigurationSource]?
    package let fetchOptions: GitFetchOptions?
    package let fetchError: GitExecutionEvent.Failure?
    package let credentialHelperEnabled: Bool
    package let interactiveAuthentication: Bool
}
package struct GitConfigurationEdit: Encodable, Sendable {
    package let root: String
    package let scope: String
    package var key: String?
    package var value: String?
    package var expectedValues: [String]?
    package init(root: URL, scope: String, key: String? = nil, value: String? = nil, expectedValues: [String]? = nil) {
        self.root = root.path; self.scope = scope; self.key = key; self.value = value; self.expectedValues = expectedValues
    }
}
package struct GitAuthenticationChallenge: Identifiable, Sendable {
    package let id: String
    package let operationID: String
    package let prompt: String
    package let secret: Bool
    package let attempt: Int
    package var retry = false
}

package struct GitConfigurationSource: Decodable, Sendable {
    package let scope: String
    package let origin: String?
}
