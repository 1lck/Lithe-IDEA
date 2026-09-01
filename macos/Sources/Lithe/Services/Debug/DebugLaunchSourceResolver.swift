import Foundation
import LitheCoreContracts

/// Selects the source file that anchors a Debug launch without making the
/// selected Run configuration depend on whichever editor tab is currently open.
struct DebugLaunchSourceResolver {
    /// Chooses a project-backed Java target when the remembered Current File
    /// entry cannot represent a launchable Java application. IDEA keeps the
    /// editor shortcut useful in this situation instead of trying to compile
    /// an arbitrary controller, repository, or configuration class alone.
    func configurationForDebug(
        selected: RunConfiguration,
        activeDocumentText: String?,
        configurations: [RunConfiguration]
    ) -> RunConfiguration {
        guard selected.usesCurrentEditorFile else {
            return selected
        }
        if activeDocumentText.map(containsJavaMainMethod) == true {
            return selected
        }

        return configurations.first {
            !$0.usesCurrentEditorFile && $0.kind.mavenFramework != nil
                && $0.kind.capabilities.contains(.jdwpDebug)
        } ?? configurations.first {
            !$0.usesCurrentEditorFile && $0.kind == .javaMain
                && $0.kind.capabilities.contains(.jdwpDebug)
        } ?? selected
    }

    func resolve(
        configuration: RunConfiguration,
        activeDocumentURL: URL?,
        projectFiles: [URL],
        workspaceURL: URL
    ) -> URL? {
        if configuration.usesCurrentEditorFile {
            return activeDocumentURL?.standardizedFileURL
        }

        let javaFiles = projectFiles
            .map(\.standardizedFileURL)
            .filter { $0.pathExtension.lowercased() == "java" }
            .sorted { $0.path < $1.path }
        guard !javaFiles.isEmpty else { return nil }

        let moduleFiles = filesInSelectedModule(
            javaFiles,
            modulePath: configuration.modulePath,
            workspaceURL: workspaceURL
        )
        let preferredFiles = moduleFiles.isEmpty ? javaFiles : moduleFiles

        if let sourceSuffix = sourceSuffix(for: configuration.mainClass),
           let exactMatch = preferredFiles.first(where: { $0.path.hasSuffix(sourceSuffix) })
                ?? javaFiles.first(where: { $0.path.hasSuffix(sourceSuffix) }) {
            return exactMatch
        }

        if let activeDocumentURL = activeDocumentURL?.standardizedFileURL,
           preferredFiles.contains(activeDocumentURL) {
            return activeDocumentURL
        }
        return preferredFiles.first
    }

    private func filesInSelectedModule(
        _ files: [URL],
        modulePath: String?,
        workspaceURL: URL
    ) -> [URL] {
        guard let modulePath = modulePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modulePath.isEmpty,
              modulePath != "." else { return files }
        let moduleURL = workspaceURL
            .appendingPathComponent(modulePath, isDirectory: true)
            .standardizedFileURL
        let modulePrefix = moduleURL.path.hasSuffix("/") ? moduleURL.path : moduleURL.path + "/"
        return files.filter { $0.path.hasPrefix(modulePrefix) }
    }

    private func sourceSuffix(for mainClass: String?) -> String? {
        guard var mainClass = mainClass?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mainClass.isEmpty else { return nil }
        if let moduleSeparator = mainClass.lastIndex(of: "/") {
            mainClass = String(mainClass[mainClass.index(after: moduleSeparator)...])
        }
        if let nestedClassSeparator = mainClass.firstIndex(of: "$") {
            mainClass = String(mainClass[..<nestedClassSeparator])
        }
        guard !mainClass.isEmpty else { return nil }
        return "/" + mainClass.replacingOccurrences(of: ".", with: "/") + ".java"
    }

    private func containsJavaMainMethod(_ source: String) -> Bool {
        source.range(
            of: #"(?m)\bstatic\s+(?:public\s+|protected\s+|private\s+)?void\s+main\s*\("#,
            options: .regularExpression
        ) != nil
    }
}
