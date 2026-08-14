import Foundation

protocol JavaMavenOperations: MavenProjectOperations, RunServerPortParsing, Sendable {
    func scanMavenProject(at rootURL: URL, files: [URL]) -> MavenProject?
    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue]
    func codeVision(
        at rootURL: URL,
        targetPath: String,
        paths: [String]
    ) -> [JavaCodeVisionValue]
    func className(source: String, simpleName: String) -> String?
    func sourceDefinition(
        source: String,
        declarationName: String,
        memberName: String?
    ) -> (line: Int, utf16Column: Int)?
    func serverPort(content: String, fileExtension: String) -> Int?
    func scanRunConfigurations(
        at rootURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) -> [JavaRunConfiguration]
    func structure(
        source: String,
        declarationSources: [String]
    ) -> JavaStructureResult?
}

struct JavaStructureResult: Sendable {
    let foldRegions: [JavaFoldRegion]
    let implementationMarkers: [JavaImplementationMarker]
    let inlayHints: [JavaInlayHint]
}

struct JavaCodeVisionValue: Sendable {
    let line: Int
    let utf16Column: Int
    let symbol: String
    let usageCount: Int
}

struct RustJavaMavenOperations: JavaMavenOperations, Sendable {
    let core: RustCoreBridge

    func scanMavenProject(at rootURL: URL, files: [URL]) -> MavenProject? {
        let root = rootURL.standardizedFileURL
        let rootComponents = root.pathComponents
        let paths = files.compactMap { fileURL -> String? in
            let file = fileURL.standardizedFileURL
            guard file.lastPathComponent.lowercased() == "pom.xml",
                  file.pathComponents.starts(with: rootComponents) else { return nil }
            return file.pathComponents
                .dropFirst(rootComponents.count)
                .joined(separator: "/")
        }
        return core.scanMaven(at: root, paths: paths)?.makeProject(workspaceRootURL: root)
    }

    func mavenDiagnostics(output: String, projectRoot: URL) -> [MavenBuildIssue] {
        guard let payload = core.mavenDiagnostics(at: projectRoot, output: output) else { return [] }
        return payload.issues.map { issue in
            let fileURL = issue.path.hasPrefix("/")
                ? URL(fileURLWithPath: issue.path)
                : projectRoot.appendingPathComponent(issue.path).standardizedFileURL
            return MavenBuildIssue(
                id: fileURL.path + ":" + String(issue.line) + ":" + String(issue.column ?? 0) + ":" + issue.message,
                fileURL: fileURL,
                line: issue.line,
                column: issue.column,
                severity: MavenIssueSeverity(rawValue: issue.severity) ?? .warning,
                message: issue.message
            )
        }
    }

    func codeVision(
        at rootURL: URL,
        targetPath: String,
        paths: [String]
    ) -> [JavaCodeVisionValue] {
        core.javaCodeVision(at: rootURL, targetPath: targetPath, paths: paths)?.hints.map {
            JavaCodeVisionValue(
                line: $0.line,
                utf16Column: $0.utf16Column,
                symbol: $0.symbol,
                usageCount: $0.usageCount
            )
        } ?? []
    }

    func className(source: String, simpleName: String) -> String? {
        core.javaClassName(source: source, simpleName: simpleName)?.className
    }

    func sourceDefinition(
        source: String,
        declarationName: String,
        memberName: String?
    ) -> (line: Int, utf16Column: Int)? {
        guard let value = core.javaSourceDefinition(
            source: source,
            declarationName: declarationName,
            memberName: memberName
        ) else { return nil }
        return (value.line, value.utf16Column)
    }

    func serverPort(content: String, fileExtension: String) -> Int? {
        core.javaServerPort(content: content, fileExtension: fileExtension)?.port
    }

    func scanRunConfigurations(
        at rootURL: URL,
        files: [URL],
        mavenProject: MavenProject?
    ) -> [JavaRunConfiguration] {
        let root = rootURL.standardizedFileURL
        let paths = files.compactMap {
            workspaceRelativePath(for: $0, root: root)
        }
        let workspaceModules = workspaceMavenModules(in: mavenProject, relativeTo: root)
        let modulePaths = workspaceModules.map(\.0)
        guard let payload = core.scanJavaRunConfigurations(
            at: root,
            paths: paths,
            modulePaths: modulePaths
        ) else { return [] }

        return payload.configurations.compactMap { value in
            guard let kind = JavaRunConfigurationKind(rawValue: value.kind) else { return nil }
            let module = value.modulePath.flatMap { modulePath in
                workspaceModules.first(where: { $0.0 == modulePath })?.1
            }
            return JavaRunConfiguration(
                id: value.id,
                name: kind == .mavenModule ? module?.displayName ?? value.name : value.name,
                kind: kind,
                modulePath: module?.relativePath ?? value.modulePath,
                mainClass: value.mainClass
            )
        }
    }

    func workspaceMavenModules(
        in project: MavenProject?,
        relativeTo root: URL
    ) -> [(path: String, module: MavenModule)] {
        project?.allModules.compactMap { module in
            workspaceRelativePath(for: module.url, root: root).map { ($0, module) }
        } ?? []
    }

    private func workspaceRelativePath(for url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    func structure(
        source: String,
        declarationSources: [String]
    ) -> JavaStructureResult? {
        guard let payload = core.javaStructure(
            source: source,
            declarationSources: declarationSources
        ) else { return nil }
        return JavaStructureResult(
            foldRegions: payload.makeFoldRegions(),
            implementationMarkers: payload.makeImplementationMarkers(),
            inlayHints: payload.makeInlayHints()
        )
    }
}
