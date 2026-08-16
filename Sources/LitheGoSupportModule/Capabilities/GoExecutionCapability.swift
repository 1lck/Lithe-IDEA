import Foundation
import LitheCoreContracts

@MainActor
public final class GoExecutionCapability: NSObject,
    LanguageRunExtensionProviding,
    LanguageTestExtensionProviding {
    public let languageID = goLanguageID
    private let sessionFactory: @MainActor () -> any LanguageExecutionSession

    public init(executionSession: any LanguageExecutionSession) {
        sessionFactory = { executionSession }
    }

    init(sessionFactory: @escaping @MainActor () -> any LanguageExecutionSession) {
        self.sessionFactory = sessionFactory
    }

    public func makeExecutionSession() -> any LanguageExecutionSession {
        sessionFactory()
    }

    public func makeTestExecutionSession() -> any LanguageExecutionSession {
        sessionFactory()
    }

    public func launchPlan(
        for request: LanguageRunExtensionRequest
    ) throws -> LanguageRunExtensionPlan {
        let path = request.relativeFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw LanguageRunExtensionError.invalidRelativePath
        }
        return LanguageRunExtensionPlan(
            executable: .toolchain("project-go"),
            arguments: ["run", path] + request.arguments,
            environment: request.environment
        )
    }

    public func discoverTests(
        for request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem] {
        let paths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isGoProject(paths) else { return [] }
        let files = paths
            .filter { $0.lowercased().hasSuffix("_test.go") }
            .sorted()
            .map { path in
                LanguageTestExtensionItem(
                    id: "go:file:\(path)",
                    label: path,
                    kind: .file,
                    relativeFilePath: path
                )
            }
        return [LanguageTestExtensionItem(
            id: "go:workspace",
            label: "All Go Tests",
            kind: .workspace
        )] + files
    }

    public func testPlan(
        for request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan {
        let projectPaths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isGoProject(projectPaths) else {
            throw LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        }
        let arguments: [String]
        let label: String
        switch request.scope {
        case .workspace:
            arguments = ["test", "./..."]
            label = "All Go Tests"
        case .file(let relativePath):
            let path = try Self.checkedRelativePath(relativePath)
            arguments = ["test", Self.packageArgument(for: path)]
            label = path.split(separator: "/").last.map(String.init) ?? path
        case .testCase(let identifier, let relativeFilePath):
            let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else {
                throw LanguageTestExtensionError.invalidTestIdentifier
            }
            let package: String
            if let relativeFilePath {
                package = Self.packageArgument(
                    for: try Self.checkedRelativePath(relativeFilePath)
                )
            } else {
                package = "./..."
            }
            arguments = [
                "test",
                package,
                "-run",
                "^\(Self.goRegularExpressionLiteral(name))$"
            ]
            label = name
        }
        return LanguageTestExtensionPlan(
            label: label,
            frameworkID: "go",
            launchPlan: LanguageRunExtensionPlan(
                executable: .toolchain("project-go"),
                arguments: arguments
            )
        )
    }

    private static func checkedRelativePath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw LanguageTestExtensionError.invalidRelativePath
        }
        return path
    }

    private static func isGoProject(_ paths: [String]) -> Bool {
        paths.contains { path in
            let name = path.split(separator: "/").last.map(String.init)?.lowercased()
            return name == "go.mod" || name == "go.work"
        }
    }

    private static func packageArgument(for relativeFilePath: String) -> String {
        let components = relativeFilePath.split(separator: "/").dropLast()
        return components.isEmpty ? "./..." : "./" + components.joined(separator: "/")
    }

    private static func goRegularExpressionLiteral(_ value: String) -> String {
        NSRegularExpression.escapedPattern(for: value)
            .replacingOccurrences(of: "\\/", with: "/")
    }
}
