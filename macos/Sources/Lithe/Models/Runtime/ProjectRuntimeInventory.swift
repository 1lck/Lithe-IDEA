import Foundation
import LitheCoreContracts
import LitheModuleAPI

enum ProjectRuntimeSubprojectKind: String, Hashable, Sendable {
    case projectDefaults
    case buildRoot
    case buildProject
    case other
}

/// A directory's local tool choices. Build providers own project hierarchy;
/// language declarations can identify directories before a model is loaded.
struct ProjectRuntimeSubproject: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ProjectRuntimeSubprojectKind
    let title: String
    let relativePath: String
    let usesJava: Bool
    let parentID: String?

    var displaysPath: Bool {
        kind != .projectDefaults && !relativePath.isEmpty && relativePath != "."
    }
}

enum ProjectRuntimeInventory {
    struct BuildSource {
        let id: String
        let root: String
        let displayName: String
        let usesJava: Bool
        let model: BuildModel?
    }
    static let projectDefaultsID = "project"

    static func subprojects(
        workspaceName: String,
        workspaceURL: URL,
        files: [URL],
        buildSources: [BuildSource],
        languageSupports: [LanguageSupportDeclaration]
    ) -> [ProjectRuntimeSubproject] {
        let root = workspaceURL.standardizedFileURL
        var result = [ProjectRuntimeSubproject(id: projectDefaultsID, kind: .projectDefaults,
            title: workspaceName, relativePath: "", usesJava: true, parentID: nil)]
        let javaMarkers = Set(languageSupports.filter { $0.id == "java" }.flatMap(\.projectFileNames))
        var javaDirectories = Set(files.filter { javaMarkers.contains($0.lastPathComponent.lowercased()) }
            .compactMap { relativePath(for: $0.deletingLastPathComponent(), root: root) })
        for source in buildSources where source.usesJava {
            javaDirectories.insert(source.root)
            javaDirectories.formUnion(source.model?.projects.map(\.path) ?? [])
        }
        var known = Set(["."])
        var modeledRoots = Set<String>()
        for source in buildSources.sorted(by: { ($0.root, $0.id) < ($1.root, $1.id) }) {
            guard validPath(source.root) else { continue }
            let rootID = directoryID(source.root)
            if known.insert(source.root).inserted {
                let project = source.model?.projects.first { $0.path == source.root }
                result.append(ProjectRuntimeSubproject(id: rootID, kind: .buildRoot,
                    title: project?.displayName ?? project?.name ?? source.displayName,
                    relativePath: source.root, usesJava: javaDirectories.contains(source.root), parentID: projectDefaultsID))
            }
            guard let model = source.model else { continue }
            modeledRoots.insert(source.root)
            let projects = Dictionary(model.projects.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
            for project in model.projects.sorted(by: { ($0.path, $0.id) < ($1.path, $1.id) }) {
                guard validPath(project.path), known.insert(project.path).inserted else { continue }
                let parent = project.parentID.flatMap { projects[$0] }.map(directoryID) ?? rootID
                result.append(ProjectRuntimeSubproject(id: directoryID(project.path), kind: .buildProject,
                    title: project.displayName ?? project.name, relativePath: project.path,
                    usesJava: javaDirectories.contains(project.path), parentID: parent))
            }
        }
        // Marker matching comes from installed declarations. It supplies only
        // directory choices, never guesses modules or overrides an engine model.
        for file in files.sorted(by: { $0.path < $1.path }) {
            let languages = languageSupports.filter { $0.projectFileNames.contains(file.lastPathComponent.lowercased()) }
            guard !languages.isEmpty,
                  let relative = relativePath(for: file.deletingLastPathComponent(), root: root),
                  validPath(relative), !known.contains(relative),
                  !modeledRoots.contains(where: { $0 == "." || relative.hasPrefix($0 + "/") }) else { continue }
            known.insert(relative)
            result.append(ProjectRuntimeSubproject(id: directoryID(relative), kind: .other,
                title: file.deletingLastPathComponent().lastPathComponent, relativePath: relative,
                usesJava: languages.contains { $0.id == "java" }, parentID: projectDefaultsID))
        }
        return result
    }

    static func workspaceRelativePath(modulePath: String?, workingDirectory: String?) -> String {
        let directory = ProjectRuntimeSettings.normalizedRelativePath(workingDirectory)
        let module = ProjectRuntimeSettings.normalizedRelativePath(modulePath)
        if directory.isEmpty { return module }
        if module.isEmpty { return directory }
        if module == directory || module.hasPrefix(directory + "/") { return module }
        return directory + "/" + module
    }

    private static func relativePath(for url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    private static func validPath(_ path: String) -> Bool {
        path == "." || !path.isEmpty && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func directoryID(_ path: String) -> String { path == "." ? projectDefaultsID : "path:" + path }
}
