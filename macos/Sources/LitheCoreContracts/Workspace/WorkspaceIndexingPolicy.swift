import Foundation

/// Directory roles and explicit indexing overrides are independent user intents.
package enum WorkspaceDirectoryAction: Equatable, Sendable {
    case setRole(WorkspaceDirectoryMark)
    case exclude
    case cancelExclusion
}

/// The persisted directory rules of one workspace root, exactly as Rust Core's
/// directory rules model (`workspace.reduceDirectoryAction`) reads and returns them.
package struct WorkspaceDirectoryRules: Codable, Equatable, Sendable {
    package var marks: [String: WorkspaceDirectoryMark]
    package var includedDirectories: [String]
    package var previousRoles: [String: WorkspaceDirectoryMark]
    package init(
        marks: [String: WorkspaceDirectoryMark],
        includedDirectories: [String],
        previousRoles: [String: WorkspaceDirectoryMark]
    ) {
        self.marks = marks
        self.includedDirectories = includedDirectories
        self.previousRoles = previousRoles
    }
}

/// Core's answer to a directory action: the full state to persist, and whether it differs.
package struct WorkspaceDirectoryReduction: Equatable, Sendable {
    package let changed: Bool
    package let rules: WorkspaceDirectoryRules
    package init(changed: Bool, rules: WorkspaceDirectoryRules) {
        self.changed = changed
        self.rules = rules
    }
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
