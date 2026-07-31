import Foundation

struct MavenProject: Identifiable, Hashable, Sendable {
    let rootURL: URL
    let pomURL: URL
    let groupID: String?
    let artifactID: String
    let version: String?
    let packaging: String
    let modules: [MavenModule]
    let profiles: [MavenProfile]
    let plugins: [MavenPlugin]
    let dependencies: [MavenDependency]
    let repositories: [MavenRepository]
    let hasWrapper: Bool

    var id: String { rootURL.path }
    var displayName: String { artifactID.isEmpty ? rootURL.lastPathComponent : artifactID }
    var isMultiModule: Bool { !modules.isEmpty }
}

struct MavenModule: Identifiable, Hashable, Sendable {
    let relativePath: String
    let url: URL
    let groupID: String?
    let artifactID: String
    let version: String?
    let packaging: String
    let modules: [MavenModule]
    let plugins: [MavenPlugin]
    let dependencies: [MavenDependency]
    let repositories: [MavenRepository]

    var id: String { relativePath }
    var displayName: String { artifactID.isEmpty ? relativePath : artifactID }
}

struct MavenProfile: Identifiable, Hashable, Sendable {
    let id: String
    let isActiveByDefault: Bool
}

struct MavenPlugin: Identifiable, Hashable, Sendable {
    let groupID: String?
    let artifactID: String
    let version: String?

    var id: String {
        [groupID ?? "org.apache.maven.plugins", artifactID, version ?? ""].joined(separator: ":")
    }

    var coordinate: String {
        [groupID ?? "org.apache.maven.plugins", artifactID, version]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ":")
    }
}

struct MavenDependency: Identifiable, Hashable, Sendable {
    let groupID: String?
    let artifactID: String
    let version: String?
    let scope: String?
    let type: String?
    let isOptional: Bool

    var id: String {
        [groupID ?? "", artifactID, version ?? "", scope ?? "", type ?? ""].joined(separator: ":")
    }

    var coordinate: String {
        [groupID, artifactID, version]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ":")
    }

    var qualifier: String? {
        let values = [scope, type == "jar" ? nil : type, isOptional ? "optional" : nil]
            .compactMap { value in
                value?.isEmpty == false ? value : nil
            }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

struct MavenRepository: Identifiable, Hashable, Sendable {
    let repositoryID: String
    let url: String

    var id: String { repositoryID + "|" + url }
    var displayName: String { repositoryID.isEmpty ? url : repositoryID }
}

enum MavenLifecyclePhase: String, CaseIterable, Identifiable, Sendable {
    case clean
    case validate
    case compile
    case test
    case packagePhase = "package"
    case verify
    case install
    case site
    case deploy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "clean"
        case .validate: "validate"
        case .compile: "compile"
        case .test: "test"
        case .packagePhase: "package"
        case .verify: "verify"
        case .install: "install"
        case .site: "site"
        case .deploy: "deploy"
        }
    }

    var systemImage: String {
        switch self {
        case .clean: "trash"
        case .validate: "checkmark.seal"
        case .compile: "hammer"
        case .test: "checkmark.circle"
        case .packagePhase: "shippingbox"
        case .verify: "checkmark.shield"
        case .install: "arrow.down.to.line"
        case .site: "globe"
        case .deploy: "arrow.up.to.line"
        }
    }
}

enum MavenIssueSeverity: String, Sendable {
    case error
    case warning
    case info

    var systemImage: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

struct MavenBuildIssue: Identifiable, Hashable, Sendable {
    let id: String
    let fileURL: URL?
    let line: Int?
    let column: Int?
    let severity: MavenIssueSeverity
    let message: String

    var locationTitle: String {
        guard let fileURL else { return "Build output" }
        let location = [line, column].compactMap { value in
            value.map(String.init)
        }.joined(separator: ":")
        return location.isEmpty ? fileURL.lastPathComponent : fileURL.lastPathComponent + ":" + location
    }
}
