import Foundation
import LitheCoreContracts

/// Selects the source file that anchors a Debug launch without making the
/// selected Run configuration depend on whichever editor tab is currently open.
struct DebugLaunchSourceResolver {
    /// Chooses a project-backed Java target when the remembered Current File
    /// entry cannot represent a launchable Java application. IDEA keeps the
    /// editor shortcut useful in this situation instead of trying to compile
    /// an arbitrary controller, repository, or configuration class alone.
    ///
    /// `activeDocumentIsLaunchable` is JDT's answer for the editor file; the
    /// source text is never scanned for a `main` signature here.
    func configurationForDebug(
        selected: RunConfiguration,
        activeDocumentIsLaunchable: Bool,
        configurations: [RunConfiguration]
    ) -> RunConfiguration {
        guard selected.usesCurrentEditorFile else {
            return selected
        }
        if activeDocumentIsLaunchable {
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

        if let sourcePath = configuration.sourcePath,
           !sourcePath.isEmpty {
            let sourceURL = workspaceURL
                .appendingPathComponent(sourcePath)
                .standardizedFileURL
            if projectFiles.map(\.standardizedFileURL).contains(sourceURL) {
                return sourceURL
            }
        }

        let javaFiles = projectFiles
            .map(\.standardizedFileURL)
            .filter { $0.pathExtension.lowercased() == "java" }
            .sorted { $0.path < $1.path }
        guard !javaFiles.isEmpty else { return nil }

        let moduleFiles = filesInSelectedModule(
            javaFiles,
            modulePath: configuration.modulePath,
            workspaceURL: configuration.mavenReactorPath.map {
                workspaceURL.appendingPathComponent($0, isDirectory: true)
            } ?? workspaceURL
        )
        // A detected Maven owner must never fall back to another reactor's class.
        let isOwned = configuration.mavenReactorPath != nil
        let preferredFiles = moduleFiles.isEmpty && !isOwned ? javaFiles : moduleFiles

        if let sourceSuffix = sourceSuffix(for: configuration.mainClass),
           let exactMatch = preferredFiles.first(where: { $0.path.hasSuffix(sourceSuffix) })
                ?? (isOwned ? nil : javaFiles.first(where: { $0.path.hasSuffix(sourceSuffix) })) {
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
        let modulePath = modulePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "."
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
}
