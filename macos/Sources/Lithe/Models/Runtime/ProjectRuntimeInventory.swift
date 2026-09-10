import Foundation
import LitheCoreContracts

enum ProjectRuntimeSubprojectKind: String, Hashable, Sendable {
    case projectDefaults
    case mavenReactor
    case mavenModule
    case other
}

/// One row in Settings → Project, including workspace defaults and nested
/// Java, Maven, or frontend roots discovered in the same workspace.
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
    static let projectDefaultsID = "project"

    static func subprojects(
        workspaceName: String,
        workspaceURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) -> [ProjectRuntimeSubproject] {
        let root = workspaceURL.standardizedFileURL
        var result: [ProjectRuntimeSubproject] = [
            ProjectRuntimeSubproject(
                id: projectDefaultsID,
                kind: .projectDefaults,
                title: workspaceName,
                relativePath: "",
                usesJava: true,
                parentID: nil
            )
        ]

        var knownJavaDirectories = Set<String>()
        if let mavenProject {
            let reactorPath = relativePath(for: mavenProject.rootURL, root: root) ?? ""
            let reactorID = mavenID(reactorPath)
            result.append(
                ProjectRuntimeSubproject(
                    id: reactorID,
                    kind: .mavenReactor,
                    title: mavenProject.displayName,
                    relativePath: normalizedDisplayPath(reactorPath),
                    usesJava: true,
                    parentID: projectDefaultsID
                )
            )
            knownJavaDirectories.insert(normalizedDirectory(reactorPath))
            appendModules(
                mavenProject.modules,
                parentID: reactorID,
                workspaceRoot: root,
                into: &result,
                knownJavaDirectories: &knownJavaDirectories
            )
        }

        for pomURL in pomFiles(in: files) {
            let directory = pomURL.deletingLastPathComponent().standardizedFileURL
            let relative = relativePath(for: directory, root: root) ?? ""
            let directoryKey = normalizedDirectory(relative)
            if knownJavaDirectories.contains(directoryKey) { continue }
            if knownJavaDirectories.contains(where: { directoryKey.hasPrefix($0 + "/") }) {
                continue
            }
            result.append(
                ProjectRuntimeSubproject(
                    id: mavenID(relative),
                    kind: .mavenReactor,
                    title: directory.lastPathComponent,
                    relativePath: normalizedDisplayPath(relative),
                    usesJava: true,
                    parentID: projectDefaultsID
                )
            )
            knownJavaDirectories.insert(directoryKey)
        }

        for packageURL in packageManifests(in: files) {
            let directory = packageURL.deletingLastPathComponent().standardizedFileURL
            let relative = relativePath(for: directory, root: root) ?? ""
            let directoryKey = normalizedDirectory(relative)
            if directoryKey.split(separator: "/").contains("node_modules") { continue }
            if knownJavaDirectories.contains(directoryKey) { continue }
            if knownJavaDirectories.contains(where: { directoryKey.hasPrefix($0 + "/") }) {
                continue
            }
            result.append(
                ProjectRuntimeSubproject(
                    id: otherID(relative),
                    kind: .other,
                    title: directory.lastPathComponent,
                    relativePath: normalizedDisplayPath(relative),
                    usesJava: false,
                    parentID: projectDefaultsID
                )
            )
        }

        return result
    }

    static func workspaceRelativePath(
        modulePath: String?,
        workingDirectory: String?
    ) -> String {
        let directory = ProjectRuntimeSettings.normalizedRelativePath(workingDirectory)
        let module = ProjectRuntimeSettings.normalizedRelativePath(modulePath)
        if directory.isEmpty { return module }
        if module.isEmpty { return directory }
        if module == directory || module.hasPrefix(directory + "/") { return module }
        return directory + "/" + module
    }

    private static func appendModules(
        _ modules: [MavenModule],
        parentID: String,
        workspaceRoot: URL,
        into result: inout [ProjectRuntimeSubproject],
        knownJavaDirectories: inout Set<String>
    ) {
        for module in modules {
            let relative = relativePath(for: module.url, root: workspaceRoot) ?? module.relativePath
            let id = moduleID(relative)
            result.append(
                ProjectRuntimeSubproject(
                    id: id,
                    kind: .mavenModule,
                    title: module.displayName,
                    relativePath: normalizedDisplayPath(relative),
                    usesJava: true,
                    parentID: parentID
                )
            )
            knownJavaDirectories.insert(normalizedDirectory(relative))
            appendModules(
                module.modules,
                parentID: id,
                workspaceRoot: workspaceRoot,
                into: &result,
                knownJavaDirectories: &knownJavaDirectories
            )
        }
    }

    private static func pomFiles(in files: [URL]) -> [URL] {
        files
            .filter { $0.lastPathComponent.lowercased() == "pom.xml" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func packageManifests(in files: [URL]) -> [URL] {
        files
            .filter { $0.lastPathComponent.lowercased() == "package.json" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func relativePath(for url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func normalizedDirectory(_ path: String) -> String {
        ProjectRuntimeSettings.normalizedRelativePath(path)
    }

    private static func normalizedDisplayPath(_ path: String) -> String {
        let normalized = ProjectRuntimeSettings.normalizedRelativePath(path)
        return normalized.isEmpty ? "." : normalized
    }

    private static func mavenID(_ path: String) -> String {
        "maven:" + normalizedDisplayPath(path)
    }

    private static func moduleID(_ path: String) -> String {
        "module:" + normalizedDisplayPath(path)
    }

    private static func otherID(_ path: String) -> String {
        "other:" + normalizedDisplayPath(path)
    }
}
