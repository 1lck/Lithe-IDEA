import Foundation

enum MavenProjectScanner {
    static func scan(at workspaceURL: URL) -> MavenProject? {
        let rootURL = workspaceURL.standardizedFileURL
        let pomURL = rootURL.appendingPathComponent("pom.xml")
        guard FileManager.default.fileExists(atPath: pomURL.path),
              let rootDescriptor = descriptor(at: pomURL) else {
            return nil
        }

        let modules = rootDescriptor.modulePaths.compactMap { rawPath -> MavenModule? in
            let relativePath = normalizedRelativePath(rawPath)
            guard !relativePath.isEmpty else { return nil }
            return module(
                at: rootURL,
                relativePath: relativePath,
                visitedPaths: [rootURL.path]
            )
        }

        return MavenProject(
            rootURL: rootURL,
            pomURL: pomURL,
            groupID: rootDescriptor.groupID,
            artifactID: rootDescriptor.artifactID ?? rootURL.lastPathComponent,
            version: rootDescriptor.version,
            packaging: rootDescriptor.packaging,
            modules: modules,
            profiles: rootDescriptor.profiles,
            plugins: rootDescriptor.plugins,
            dependencies: rootDescriptor.dependencies,
            repositories: rootDescriptor.repositories,
            hasWrapper: hasMavenWrapper(at: rootURL)
        )
    }

    private static func module(
        at rootURL: URL,
        relativePath: String,
        visitedPaths: Set<String>
    ) -> MavenModule? {
        let moduleURL = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard !visitedPaths.contains(moduleURL.path) else { return nil }

        let moduleDescriptor = descriptor(at: moduleURL.appendingPathComponent("pom.xml"))
        let nextVisitedPaths = visitedPaths.union([moduleURL.path])
        let childModules = moduleDescriptor?.modulePaths.compactMap { rawPath -> MavenModule? in
            let childURL = moduleURL
                .appendingPathComponent(normalizedRelativePath(rawPath))
                .standardizedFileURL
            guard let childRelativePath = rootRelativePath(from: rootURL, to: childURL),
                  !childRelativePath.isEmpty else { return nil }
            return module(
                at: rootURL,
                relativePath: childRelativePath,
                visitedPaths: nextVisitedPaths
            )
        } ?? []

        return MavenModule(
            relativePath: relativePath,
            url: moduleURL,
            groupID: moduleDescriptor?.groupID,
            artifactID: moduleDescriptor?.artifactID ?? moduleURL.lastPathComponent,
            version: moduleDescriptor?.version,
            packaging: moduleDescriptor?.packaging ?? "jar",
            modules: childModules,
            plugins: moduleDescriptor?.plugins ?? [],
            dependencies: moduleDescriptor?.dependencies ?? [],
            repositories: moduleDescriptor?.repositories ?? []
        )
    }

    private static func rootRelativePath(from rootURL: URL, to childURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let childPath = childURL.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else { return nil }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private static func normalizedRelativePath(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasMavenWrapper(at rootURL: URL) -> Bool {
        let wrapper = rootURL.appendingPathComponent("mvnw")
        let windowsWrapper = rootURL.appendingPathComponent("mvnw.cmd")
        return FileManager.default.isExecutableFile(atPath: wrapper.path) ||
            FileManager.default.fileExists(atPath: windowsWrapper.path)
    }

    private static func descriptor(at pomURL: URL) -> Descriptor? {
        guard FileManager.default.fileExists(atPath: pomURL.path),
              let parser = XMLParser(contentsOf: pomURL) else { return nil }
        let delegate = MavenXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.descriptor
    }

    private struct Descriptor {
        let groupID: String?
        let artifactID: String?
        let version: String?
        let packaging: String
        let modulePaths: [String]
        let profiles: [MavenProfile]
        let plugins: [MavenPlugin]
        let dependencies: [MavenDependency]
        let repositories: [MavenRepository]
    }

    private final class MavenXMLDelegate: NSObject, XMLParserDelegate {
        private(set) var descriptor: Descriptor?
        private var elementStack: [String] = []
        private var currentText = ""

        private var groupID: String?
        private var artifactID: String?
        private var version: String?
        private var packaging = "jar"
        private var modulePaths: [String] = []
        private var profiles: [MavenProfile] = []
        private var plugins: [MavenPlugin] = []
        private var dependencies: [MavenDependency] = []
        private var repositories: [MavenRepository] = []

        private var profileID: String?
        private var profileActiveByDefault = false

        private var dependencyGroupID: String?
        private var dependencyArtifactID: String?
        private var dependencyVersion: String?
        private var dependencyScope: String?
        private var dependencyType: String?
        private var dependencyOptional = false

        private var pluginGroupID: String?
        private var pluginArtifactID: String?
        private var pluginVersion: String?

        private var repositoryID = ""
        private var repositoryURL = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elementStack.append(elementName)
            currentText = ""

            switch elementName {
            case "profile":
                profileID = nil
                profileActiveByDefault = false
            case "dependency":
                dependencyGroupID = nil
                dependencyArtifactID = nil
                dependencyVersion = nil
                dependencyScope = nil
                dependencyType = nil
                dependencyOptional = false
            case "plugin":
                pluginGroupID = nil
                pluginArtifactID = nil
                pluginVersion = nil
            case "repository":
                repositoryID = ""
                repositoryURL = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = elementStack.joined(separator: "/")

            switch path {
            case "project/groupId", "project/parent/groupId":
                if groupID == nil || path == "project/groupId" { groupID = value }
            case "project/artifactId":
                artifactID = value
            case "project/version", "project/parent/version":
                if version == nil || path == "project/version" { version = value }
            case "project/packaging":
                packaging = value.isEmpty ? "jar" : value
            case "project/modules/module":
                if !value.isEmpty { modulePaths.append(value) }
            case "project/profiles/profile/id":
                profileID = value
            case "project/profiles/profile/activation/activeByDefault":
                profileActiveByDefault = value.lowercased() == "true"
            case "project/dependencies/dependency/groupId":
                dependencyGroupID = value
            case "project/dependencies/dependency/artifactId":
                dependencyArtifactID = value
            case "project/dependencies/dependency/version":
                dependencyVersion = value
            case "project/dependencies/dependency/scope":
                dependencyScope = value
            case "project/dependencies/dependency/type":
                dependencyType = value
            case "project/dependencies/dependency/optional":
                dependencyOptional = value.lowercased() == "true"
            case "project/build/plugins/plugin/groupId", "project/build/pluginManagement/plugins/plugin/groupId":
                pluginGroupID = value
            case "project/build/plugins/plugin/artifactId", "project/build/pluginManagement/plugins/plugin/artifactId":
                pluginArtifactID = value
            case "project/build/plugins/plugin/version", "project/build/pluginManagement/plugins/plugin/version":
                pluginVersion = value
            case "project/repositories/repository/id":
                repositoryID = value
            case "project/repositories/repository/url":
                repositoryURL = value
            default:
                break
            }

            if elementName == "dependency", isProjectDependencyPath(path),
               let dependencyArtifactID, !dependencyArtifactID.isEmpty {
                appendDependency(MavenDependency(
                    groupID: dependencyGroupID,
                    artifactID: dependencyArtifactID,
                    version: dependencyVersion,
                    scope: dependencyScope,
                    type: dependencyType,
                    isOptional: dependencyOptional
                ))
            }

            if elementName == "plugin", isProjectPluginPath(path),
               let pluginArtifactID, !pluginArtifactID.isEmpty {
                appendPlugin(MavenPlugin(
                    groupID: pluginGroupID,
                    artifactID: pluginArtifactID,
                    version: pluginVersion
                ))
            }

            if elementName == "repository", path == "project/repositories/repository",
               !repositoryID.isEmpty || !repositoryURL.isEmpty {
                appendRepository(MavenRepository(repositoryID: repositoryID, url: repositoryURL))
            }

            if elementName == "profile", path == "project/profiles/profile",
               let profileID, !profileID.isEmpty,
               !profiles.contains(where: { $0.id == profileID }) {
                profiles.append(MavenProfile(id: profileID, isActiveByDefault: profileActiveByDefault))
            }

            _ = elementStack.popLast()
            currentText = ""
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            descriptor = Descriptor(
                groupID: groupID,
                artifactID: artifactID,
                version: version,
                packaging: packaging,
                modulePaths: modulePaths,
                profiles: profiles,
                plugins: plugins,
                dependencies: dependencies,
                repositories: repositories
            )
        }

        private func isProjectDependencyPath(_ path: String) -> Bool {
            path == "project/dependencies/dependency"
        }

        private func isProjectPluginPath(_ path: String) -> Bool {
            path == "project/build/plugins/plugin" ||
                path == "project/build/pluginManagement/plugins/plugin"
        }

        private func appendPlugin(_ plugin: MavenPlugin) {
            guard !plugins.contains(where: { $0.id == plugin.id }) else { return }
            plugins.append(plugin)
        }

        private func appendDependency(_ dependency: MavenDependency) {
            guard !dependencies.contains(where: { $0.id == dependency.id }) else { return }
            dependencies.append(dependency)
        }

        private func appendRepository(_ repository: MavenRepository) {
            guard !repositories.contains(where: { $0.id == repository.id }) else { return }
            repositories.append(repository)
        }
    }
}
