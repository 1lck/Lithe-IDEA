import Foundation

/// Directory roles and explicit indexing overrides are independent user intents.
package enum WorkspaceDirectoryAction: Equatable, Sendable {
    case setRole(WorkspaceDirectoryMark)
    case exclude
    case cancelExclusion
}

/// Stable application failures. Presentation owns translation; adapters retain diagnostics.
package enum WorkspaceIndexingFailure: Error, Equatable, Sendable {
    case invalidSettings, readFailed, writeFailed, configureFailed, workspaceUnavailable, permissionDenied
}

/// Project preferences are separate from roles and from tree-hiding rules.
package struct WorkspaceIndexingSettings: Codable, Equatable, Sendable {
    package var gitIgnoreEnabled = true
    package var includedDirectories: [String] = []
    package var previousRoles: [String: WorkspaceDirectoryMark] = [:]
    package init() {}
}

package struct WorkspaceIndexingPolicy: Encodable, Equatable, Sendable {
    package let manualExcludedDirectories: [String]
    package let includedDirectories: [String]
    package let gitIgnoreEnabled: Bool
    package init(marks: [String: WorkspaceDirectoryMark], settings: WorkspaceIndexingSettings) {
        manualExcludedDirectories = marks.filter { $0.value == .excluded }.map(\.key).sorted()
        includedDirectories = settings.includedDirectories.sorted()
        gitIgnoreEnabled = settings.gitIgnoreEnabled
    }
}

package struct WorkspaceIndexingStatus: Decodable, Sendable {
    package var revision: UInt64 = 0
    package var excludedDirectories: [String: String] = [:]
    // Local transport capability; deliberately absent from the Core JSON contract.
    package var supportsExclusions = true
    private enum CodingKeys: String, CodingKey {
        case revision, excludedDirectories, gitIgnoreFailed
    }
    package var gitIgnoreFailed = false
    package init() {}
}
