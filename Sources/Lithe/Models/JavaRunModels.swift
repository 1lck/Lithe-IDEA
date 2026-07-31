import Foundation

struct JavaRunOptions: Codable, Hashable, Sendable {
    var javaHomePath = ""
    var workingDirectoryPath = ""
    var vmArguments = ""
    var programArguments = ""
    var activeProfiles: Set<String> = []
}

struct JavaRunSession: Identifiable, Hashable, Sendable {
    let id: String
    let configurationID: String
    let title: String
    var output: String
    var isRunning: Bool
    var exitCode: Int32?
}

struct JavaRunPortConflict: Identifiable, Hashable, Sendable {
    let port: Int
    let configurationNames: [String]

    var id: String { String(port) }

    var title: String {
        "Port (port) is used by " + configurationNames.joined(separator: ", ")
    }
}

enum JavaRunConfigurationKind: String, Identifiable, Sendable {
    case currentFile
    case springBoot
    case mavenModule

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentFile: "Current File"
        case .springBoot: "Spring Boot"
        case .mavenModule: "Maven Module"
        }
    }

    var systemImage: String {
        switch self {
        case .currentFile: "doc.text"
        case .springBoot: "leaf"
        case .mavenModule: "shippingbox"
        }
    }
}

struct JavaRunConfiguration: Identifiable, Hashable, Sendable {
    static let currentFileID = "current-file"

    let id: String
    let name: String
    let kind: JavaRunConfigurationKind
    let modulePath: String?
    let mainClass: String?

    var systemImage: String { kind.systemImage }

    static var currentFile: JavaRunConfiguration {
        JavaRunConfiguration(
            id: currentFileID,
            name: "Current File",
            kind: .currentFile,
            modulePath: nil,
            mainClass: nil
        )
    }
}
