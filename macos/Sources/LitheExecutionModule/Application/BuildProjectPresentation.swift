import Foundation
import LitheCoreContracts

/// Read-only labels and source roles from upstream build models. No descriptor
/// parsing or file-name inference belongs in this presentation projection.
package enum BuildProjectPresentation {
    package static func projectName(for file: URL, workspace: URL, models: [BuildModel]) -> String? {
        models.flatMap(\.projects).compactMap { project -> (String, String)? in
            guard let directory = containingDirectory(project.path, file: file, workspace: workspace) else { return nil }
            return (directory, project.displayName ?? project.name)
        }.sorted { left, right in
            if left.0.count != right.0.count { return left.0.count > right.0.count }
            return left < right
        }.first?.1
    }

    package static func sourceRootKind(for file: URL, workspace: URL, models: [BuildModel]) -> String? {
        let sourceKinds: Set<String> = ["source", "resource", "testSource", "testResource", "generatedSource", "generatedTestSource"]
        return models.flatMap(\.contentRoots).compactMap { root -> (String, String)? in
            guard sourceKinds.contains(root.kind),
                  let directory = containingDirectory(root.path, file: file, workspace: workspace) else { return nil }
            return (directory, root.kind)
        }.sorted { left, right in
            if left.0.count != right.0.count { return left.0.count > right.0.count }
            return left < right
        }.first?.1
    }

    private static func containingDirectory(_ path: String, file: URL, workspace: URL) -> String? {
        guard file.isFileURL, workspace.isFileURL, !path.hasPrefix("/") else { return nil }
        let root = workspace.standardizedFileURL.path
        let directory = workspace.appendingPathComponent(path).standardizedFileURL.path
        let target = file.standardizedFileURL.path
        guard directory == root || directory.hasPrefix(root + "/"),
              target == directory || target.hasPrefix(directory + "/") else { return nil }
        return directory
    }
}
