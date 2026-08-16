import Foundation
import LitheGitModule

enum JavaCodeVisionService {
    static func hints(
        for fileURL: URL,
        projectFiles: [URL],
        workspaceRoot: URL,
        blameLines: [GitBlameLine],
        operations: any JavaMavenOperations
    ) async -> [JavaCodeVisionHint] {
        let root = workspaceRoot.standardizedFileURL
        let target = fileURL.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"),
              let targetPath = relativePath(target, root: root) else { return [] }
        let paths = projectFiles.compactMap { file -> String? in
            let normalized = file.standardizedFileURL
            guard normalized.path.hasPrefix(root.path + "/") else { return nil }
            return relativePath(normalized, root: root)
        }
        let values = await Task.detached(priority: .utility) {
            operations.codeVision(
                at: root,
                targetPath: targetPath,
                paths: paths
            )
        }.value
        let blameByLine = Dictionary(uniqueKeysWithValues: blameLines.map { ($0.line, $0) })
        return values.map { value in
            JavaCodeVisionHint(
                line: value.line,
                utf16Column: value.utf16Column,
                symbol: value.symbol,
                usageCount: value.usageCount,
                implementationCount: 0,
                authorName: blameByLine[value.line]?.authorName
            )
        }
    }

    private static func relativePath(_ file: URL, root: URL) -> String? {
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return String(file.path.dropFirst(root.path.count + 1))
    }
}
