import Foundation

/// Pure Core Git planners. They never start Git or read a repository; the app
/// collects facts, Core decides, and the app executes and presents the result.
package enum GitCorePlanCommand: String, Sendable {
    case normalizeChangeTargets = "git.normalizeChangeTargets"
}

// MARK: - git.normalizeChangeTargets

package struct GitChangeTargetsRequest: Encodable, Sendable {
    package struct Target: Encodable, Sendable {
        package let root: String
        package let path: String
        package let untrackedDirectory: Bool
    }
    package let targets: [Target]

    package init(_ changes: [GitChange]) {
        targets = changes.map {
            Target(root: $0.repositoryRoot.standardizedFileURL.path, path: $0.path,
                   untrackedDirectory: $0.isUntrackedDirectory)
        }
    }
}

package struct GitChangeTargetsPlan: Decodable, Sendable {
    package let indices: [Int]
}
