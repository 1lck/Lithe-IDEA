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
            return module(at: rootURL, relativePath: relativePath, visitedPaths: [rootURL.path])
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
            let childPath = normalizedRelativePath(rawPath)
            guard !childPath.isEmpty else { return nil }
            let childURL = moduleURL.appendingPathComponent(childPath).standardizedFileURL
            guard let childRelativePath = rootRelativePath(from: rootURL, to: childURL) else { return nil }
            return module(at: rootURL, relativePath: childRelativePath, visitedPaths: nextVisitedPaths)
        } ?? []

        return MavenModule(
            relativePath: relativePath,
            url: moduleURL,
            groupID: moduleDescriptor?.groupID,
            artifactID: moduleDescriptor?.artifactID ?? moduleURL.lastPathComponent,
            version: moduleDescriptor?.version,
            packaging: moduleDescriptor?.packaging ?? "jar",
            modules: childModules
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
        private var profileID: String?
        private var profileActiveByDefault = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            elementStack.append(elementName)
            currentText = ""
            if elementName == "profile" {
                profileID = nil
                profileActiveByDefault = false
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
            default:
                break
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
                profiles: profiles
            )
        }
    }
}
