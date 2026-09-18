import Foundation
import LitheCoreContracts

/// Interprets PHP projects for the run and test features. PHP has no toolchain
/// registered in the shared run configuration generator, so both plans launch
/// the `php` executable the user already has on PATH instead of a toolchain ID.
@MainActor
public final class PhpExecutionCapability: NSObject,
    LanguageRunExtensionProviding,
    LanguageTestExtensionProviding {
    public let languageID = phpLanguageID
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
            executable: .command("php"),
            arguments: [path] + request.arguments,
            environment: request.environment
        )
    }

    public func discoverTests(
        for request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem] {
        let paths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isPhpProject(paths) else { return [] }
        let files = paths
            .filter { Self.isPhpTestFile($0) }
            .sorted()
            .map { path in
                LanguageTestExtensionItem(
                    id: "php:file:\(path)",
                    label: path,
                    kind: .file,
                    relativeFilePath: path
                )
            }
        return [LanguageTestExtensionItem(
            id: "php:workspace",
            label: "All PHP Tests",
            kind: .workspace
        )] + files
    }

    public func testPlan(
        for request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan {
        let projectPaths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isPhpProject(projectPaths) else {
            throw LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        }
        let arguments: [String]
        let label: String
        switch request.scope {
        case .workspace:
            arguments = [Self.phpUnitEntryPoint]
            label = "All PHP Tests"
        case .file(let relativePath):
            let path = try Self.checkedRelativePath(relativePath)
            arguments = [Self.phpUnitEntryPoint, path]
            label = path.split(separator: "/").last.map(String.init) ?? path
        case .testCase(let identifier, let relativeFilePath):
            let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else {
                throw LanguageTestExtensionError.invalidTestIdentifier
            }
            var caseArguments = [
                Self.phpUnitEntryPoint,
                "--filter",
                Self.phpUnitFilterExpression(name)
            ]
            if let relativeFilePath {
                caseArguments.append(try Self.checkedRelativePath(relativeFilePath))
            }
            arguments = caseArguments
            label = name
        }
        return LanguageTestExtensionPlan(
            label: label,
            frameworkID: "phpunit",
            launchPlan: LanguageRunExtensionPlan(
                executable: .command("php"),
                arguments: arguments
            )
        )
    }

    /// PHPUnit ships inside the project through Composer, so the plan addresses
    /// the vendor entry point relative to the workspace root.
    private static let phpUnitEntryPoint = "vendor/bin/phpunit"

    private static func checkedRelativePath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw LanguageTestExtensionError.invalidRelativePath
        }
        return path
    }

    private static func isPhpProject(_ paths: [String]) -> Bool {
        paths.contains { path in
            let name = path.split(separator: "/").last.map(String.init)?.lowercased()
            return name == "composer.json"
                || name == "phpunit.xml"
                || name == "phpunit.xml.dist"
        }
    }

    private static func isPhpTestFile(_ relativeFilePath: String) -> Bool {
        let name = relativeFilePath.split(separator: "/").last.map(String.init) ?? relativeFilePath
        return name.lowercased().hasSuffix("test.php")
    }

    /// PHPUnit matches `--filter` against the full `<Class>::<method>` test ID, so
    /// an anchored bare method name such as `^name$` never matches and PHPUnit
    /// reports "No tests executed". Word boundaries select exactly the requested
    /// method instead: without them a bare substring would also run every method
    /// that shares the name as a prefix. Boundaries still match names that carry a
    /// data-provider suffix.
    private static func phpUnitFilterExpression(_ value: String) -> String {
        let literal = NSRegularExpression.escapedPattern(for: value)
            .replacingOccurrences(of: "\\/", with: "/")
        return "\\b\(literal)\\b"
    }
}
