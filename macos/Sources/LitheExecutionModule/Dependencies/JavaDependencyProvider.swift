import Foundation
import LitheCoreContracts

/// Projects the Java classpath already resolved by the execution runtime into
/// the language-neutral dependency browser model.
package struct JavaDependencyProvider: WorkspaceDependencyProvider {
    package let providerID = "java"

    package init() {}

    /// Returns the conventional JDK source archive for a registered JDK home.
    /// The runtime locator remains responsible for validating that the archive
    /// exists; this provider only preserves the resolved service configuration.
    package static func sourceArchive(for javaHome: URL) -> URL {
        javaHome.standardizedFileURL.appendingPathComponent("lib/src.zip")
    }

    package func resolve(
        context: DependencyResolutionContext
    ) async throws -> DependencyGraph {
        var seenPaths: Set<String> = []
        var entries = context.classpath
            .map(Self.makeNode)
            .filter { seenPaths.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                guard titleOrder == .orderedSame else {
                    return titleOrder == .orderedAscending
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }

        if let jdkSourceArchive = context.jdkSourceArchive {
            entries.insert(
                DependencyNode(
                    id: "jdk:\(jdkSourceArchive.standardizedFileURL.path)",
                    title: "JDK Sources",
                    subtitle: context.serviceDisplayName,
                    kind: .packageNode,
                    source: .archive(jdkSourceArchive)
                ),
                at: 0
            )
        }

        return DependencyGraph(
            providerID: providerID,
            serviceID: context.serviceID,
            roots: entries
        )
    }

    private static func makeNode(for url: URL) -> DependencyNode {
        let normalized = url.standardizedFileURL
        let name = normalized.lastPathComponent.isEmpty
            ? normalized.path
            : normalized.lastPathComponent
        let isDirectory = normalized.hasDirectoryPath
        let isArchive = normalized.pathExtension.lowercased() == "jar"
            || normalized.pathExtension.lowercased() == "zip"
        let kind: DependencyNodeKind = isDirectory || isArchive ? .packageNode : .file
        let source: DependencySource
        if isDirectory {
            source = .directory(normalized)
        } else if isArchive {
            source = .archive(normalized)
        } else {
            source = .unavailable
        }

        return DependencyNode(
            id: normalized.path,
            title: name,
            subtitle: normalized.path,
            kind: kind,
            source: source
        )
    }
}
