import Foundation

enum JavaRunConfigurationScanner {
    static func scan(
        files: [URL],
        mavenProject: MavenProject?
    ) -> [JavaRunConfiguration] {
        let mainClasses = files
            .filter { $0.pathExtension.lowercased() == "java" }
            .compactMap { fileURL -> JavaMainClass? in
                guard let source = try? String(contentsOf: fileURL, encoding: .utf8),
                      let mainClass = mainClass(in: source, fileURL: fileURL) else { return nil }
                return mainClass
            }

        var configurations: [JavaRunConfiguration] = []
        for mainClass in mainClasses where mainClass.isSpringBoot {
            let modulePath = modulePath(for: mainClass.fileURL, in: mavenProject)
            configurations.append(JavaRunConfiguration(
                id: "spring:" + mainClass.qualifiedName,
                name: mainClass.simpleName,
                kind: .springBoot,
                modulePath: modulePath,
                mainClass: mainClass.qualifiedName
            ))
        }

        if let mavenProject {
            for module in mavenProject.modules {
                let moduleMainClass = mainClasses.first {
                    isInside($0.fileURL, directory: module.url)
                }
                configurations.append(JavaRunConfiguration(
                    id: "module:" + module.relativePath,
                    name: module.displayName,
                    kind: .mavenModule,
                    modulePath: module.relativePath,
                    mainClass: moduleMainClass?.qualifiedName
                ))
            }
        }

        return configurations.sorted {
            if $0.kind != $1.kind { return kindOrder($0.kind) < kindOrder($1.kind) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private struct JavaMainClass {
        let fileURL: URL
        let qualifiedName: String
        let simpleName: String
        let isSpringBoot: Bool
    }

    private static func mainClass(in source: String, fileURL: URL) -> JavaMainClass? {
        guard source.range(of: "static void main") != nil || source.range(of: "static final void main") != nil else {
            return nil
        }
        guard let simpleName = firstCapture(
            pattern: #"\b(?:public\s+)?(?:final\s+)?class\s+([A-Za-z_$][A-Za-z0-9_$]*)"#,
            in: source
        ) else { return nil }
        let packageName = firstCapture(
            pattern: #"(?m)^\s*package\s+([A-Za-z_$][A-Za-z0-9_$.]*)\s*;"#,
            in: source
        )
        let qualifiedName = packageName.map { $0 + "." + simpleName } ?? simpleName
        return JavaMainClass(
            fileURL: fileURL,
            qualifiedName: qualifiedName,
            simpleName: simpleName,
            isSpringBoot: source.contains("@SpringBootApplication")
        )
    }

    private static func modulePath(for fileURL: URL, in project: MavenProject?) -> String? {
        project?.modules
            .filter { isInside(fileURL, directory: $0.url) }
            .max(by: { $0.url.path.count < $1.url.path.count })?
            .relativePath
    }

    private static func isInside(_ fileURL: URL, directory: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return filePath.hasPrefix(directoryPath + "/")
    }

    private static func firstCapture(pattern: String, in source: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: source,
                range: NSRange(source.startIndex..<source.endIndex, in: source)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }

    private static func kindOrder(_ kind: JavaRunConfigurationKind) -> Int {
        switch kind {
        case .currentFile: 0
        case .springBoot: 1
        case .mavenModule: 2
        }
    }
}
