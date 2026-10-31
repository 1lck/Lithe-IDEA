import Foundation

package struct MavenProfile: Identifiable, Hashable, Sendable {
    package let id: String
    package let isActiveByDefault: Bool

    package init(id: String, isActiveByDefault: Bool) {
        self.id = id
        self.isActiveByDefault = isActiveByDefault
    }
}

package enum MavenLifecyclePhase: String, CaseIterable, Identifiable, Sendable {
    case clean, validate, compile, test
    case packagePhase = "package"
    case verify, install, site, deploy

    package var id: String { rawValue }
    package var title: String { rawValue }
    package var systemImage: String {
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

package enum MavenIssueSeverity: String, Sendable {
    case error, warning, info

    package var systemImage: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

package struct MavenBuildIssue: Identifiable, Hashable, Sendable {
    package let id: String
    package let fileURL: URL?
    package let line: Int?
    package let column: Int?
    package let severity: MavenIssueSeverity
    package let message: String

    package init(id: String, fileURL: URL?, line: Int?, column: Int?, severity: MavenIssueSeverity, message: String) {
        self.id = id
        self.fileURL = fileURL
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }

    package var locationTitle: String {
        guard let fileURL else { return "Build output" }
        let location = [line, column].compactMap { $0.map(String.init) }.joined(separator: ":")
        return location.isEmpty ? fileURL.lastPathComponent : fileURL.lastPathComponent + ":" + location
    }
}

package struct MavenLaunchContext: Codable, Equatable, Sendable {
    package static let currentVersion = 1

    package let version: Int
    package let reactorPath: String
    package let profiles: [String]
    package let settingsPath: String?
    package let localRepositoryPath: String?
    package let skipTests: Bool
    package let mavenExecutablePath: String?
    package let javaHomePath: String?

    /// Language-import contexts omit execution-only choices such as Skip Tests.
    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        reactorPath = try values.decode(String.self, forKey: .reactorPath)
        profiles = try values.decode([String].self, forKey: .profiles)
        settingsPath = try values.decodeIfPresent(String.self, forKey: .settingsPath)
        localRepositoryPath = try values.decodeIfPresent(String.self, forKey: .localRepositoryPath)
        skipTests = try values.decodeIfPresent(Bool.self, forKey: .skipTests) ?? false
        mavenExecutablePath = try values.decodeIfPresent(String.self, forKey: .mavenExecutablePath)
        javaHomePath = try values.decodeIfPresent(String.self, forKey: .javaHomePath)
    }

    package init(
        version: Int = currentVersion,
        reactorPath: String,
        profiles: [String],
        settingsPath: String?,
        localRepositoryPath: String? = nil,
        skipTests: Bool,
        mavenExecutablePath: String?,
        javaHomePath: String?
    ) {
        self.version = version
        self.reactorPath = reactorPath
        self.profiles = profiles
        self.settingsPath = settingsPath
        self.localRepositoryPath = localRepositoryPath
        self.skipTests = skipTests
        self.mavenExecutablePath = mavenExecutablePath
        self.javaHomePath = javaHomePath
    }
}

package func redactedMavenArgumentsForDisplay(_ arguments: [String]) -> [String] {
    var result: [String] = []
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "-s" || argument == "--settings" {
            result.append(argument)
            if arguments.indices.contains(index + 1) {
                result.append("<settings.xml>")
                index += 2
            } else {
                index += 1
            }
        } else if argument.hasPrefix("--settings=") || argument.hasPrefix("-s=") {
            result.append(String(argument.prefix { $0 != "=" }) + "=<settings.xml>")
            index += 1
        } else if argument.hasPrefix("-Dmaven.repo.local=") {
            result.append("-Dmaven.repo.local=<localRepository>")
            index += 1
        } else {
            result.append(argument)
            index += 1
        }
    }
    return result
}

package struct MavenOperationError: LocalizedError, Equatable, Sendable {
    package let code: String
    package let message: String
    package let details: String?

    package init(code: String, message: String, details: String? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    package var errorDescription: String? {
        guard let details, !details.isEmpty else { return message }
        return message + ": " + details
    }
}
