import Foundation
import LitheCoreContracts

package enum LanguageTestPlanError: LocalizedError, Equatable, Sendable {
    case unsupportedProvider(String)
    case extensionNotActive(String)
    case fileOutsideWorkspace(URL)

    package var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "No test runner is configured for \(provider)."
        case .extensionNotActive(let provider):
            return "\(provider) testing extension is not active."
        case .fileOutsideWorkspace(let url):
            return "The test file is outside the current workspace: \(url.path)"
        }
    }
}

package struct StandardLanguageTestProvider: LanguageTestProvider {
    private enum StandardTestFramework: String {
        case maven
        case gradle
        case go
        case pytest
        case npm
        case pnpm
        case yarn
        case bun
        case cargo
    }

    package let descriptor: LanguageProviderDescriptor

    package init(descriptor: LanguageProviderDescriptor) {
        self.descriptor = descriptor
    }

    package func discoverTests(workspaceURL: URL, files: [URL]) -> [LanguageTestItem] {
        makeTestItems(workspaceURL: workspaceURL, files: files)
    }

    /// Real workspace discovery carries project markers so a plain source
    /// directory is not misidentified as Maven/npm/Cargo merely because it
    /// contains a file whose name looks like a test. The legacy overload above
    /// remains permissive for callers that only have a file list.
    package func discoverTests(context: LanguageTestContext) -> [LanguageTestItem] {
        guard framework(for: descriptor.id, context: context) != nil else { return [] }
        return makeTestItems(
            workspaceURL: context.workspaceURL,
            files: context.projectFiles
        )
    }

    private func makeTestItems(workspaceURL: URL, files: [URL]) -> [LanguageTestItem] {
        let root = workspaceURL.standardizedFileURL
        let workspace = LanguageTestItem(
            id: descriptor.id + ":workspace",
            providerID: descriptor.id,
            label: "All \(descriptor.displayName) Tests",
            kind: .workspace,
            fileURL: nil
        )
        let discovered = files
            .map(\.standardizedFileURL)
            .filter { isInsideWorkspace($0, root: root) && isTestFile($0, root: root) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { url in
                LanguageTestItem(
                    id: descriptor.id + ":file:" + relativePath(url, root: root),
                    providerID: descriptor.id,
                    label: relativePath(url, root: root),
                    kind: .file,
                    fileURL: url
                )
            }
        return [workspace] + discovered
    }

    package func testPlan(
        scope: LanguageTestScope,
        context: LanguageTestContext
    ) throws -> LanguageTestPlan {
        let root = context.workspaceURL
        guard let framework = framework(for: descriptor.id, context: context) else {
            throw LanguageTestPlanError.unsupportedProvider(descriptor.displayName)
        }
        let plan: SharedLaunchPlan
        switch framework {
        case .maven:
            plan = SharedLaunchPlan(
                executable: .toolchain("project-maven"),
                arguments: javaArguments(scope: scope, root: root),
                workingDirectory: "."
            )
        case .gradle:
            plan = SharedLaunchPlan(
                executable: .toolchain("project-gradle"),
                arguments: try gradleArguments(scope: scope, root: root),
                workingDirectory: "."
            )
        case .go:
            plan = SharedLaunchPlan(
                executable: .toolchain("project-go"),
                arguments: try goArguments(scope: scope, root: root),
                workingDirectory: "."
            )
        case .pytest:
            plan = SharedLaunchPlan(
                executable: .toolchain("project-python"),
                arguments: try pythonArguments(scope: scope, root: root),
                workingDirectory: "."
            )
        case .npm, .pnpm, .yarn, .bun:
            plan = SharedLaunchPlan(
                executable: .command(framework.rawValue),
                arguments: try nodeArguments(
                    framework: framework,
                    scope: scope,
                    root: root
                ),
                workingDirectory: "."
            )
        case .cargo:
            plan = SharedLaunchPlan(
                executable: .toolchain("project-cargo"),
                arguments: try rustArguments(scope: scope, root: root),
                workingDirectory: "."
            )
        }
        return LanguageTestPlan(
            providerID: descriptor.id,
            label: testLabel(scope: scope),
            frameworkID: framework.rawValue,
            launchPlan: plan
        )
    }

    private func framework(
        for providerID: String,
        context: LanguageTestContext
    ) -> StandardTestFramework? {
        let names = context.projectFileNames
        switch providerID {
        case "java":
            if names.contains("build.gradle")
                || names.contains("build.gradle.kts")
                || names.contains("gradlew") {
                return .gradle
            }
            // Keep the old workspaceURL-only overload usable by treating an
            // empty marker set as Maven, but never claim Maven for a real
            // workspace that has no Maven/Gradle descriptor.
            return names.isEmpty || names.contains("pom.xml") ? .maven : nil
        case "go":
            return context.projectFiles.isEmpty
                || names.contains("go.mod")
                || names.contains("go.work") ? .go : nil
        case "python":
            let pythonMarkers = ["pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini"]
            return context.projectFiles.isEmpty
                || !names.isDisjoint(with: pythonMarkers) ? .pytest : nil
        case "node":
            if names.contains("pnpm-lock.yaml") { return .pnpm }
            if names.contains("yarn.lock") { return .yarn }
            if names.contains("bun.lock") || names.contains("bun.lockb") { return .bun }
            return names.isEmpty || names.contains("package.json") ? .npm : nil
        case "rust":
            return names.isEmpty || names.contains("cargo.toml") ? .cargo : nil
        default: return nil
        }
    }

    private func isTestFile(_ url: URL, root: URL) -> Bool {
        guard descriptor.handles(fileURL: url) else { return false }
        let name = url.lastPathComponent.lowercased()
        let relative = relativePath(url, root: root).lowercased()
        switch descriptor.id {
        case "java":
            return relative.contains("/src/test/") || name.hasSuffix("test.java") || name.hasSuffix("tests.java")
        case "go":
            return name.hasSuffix("_test.go")
        case "python":
            return name.hasPrefix("test_") || name.hasSuffix("_test.py")
        case "node":
            return [".test.", ".spec."].contains { name.contains($0) }
                || relative.contains("/__tests__/")
        case "rust":
            return relative.hasPrefix("tests/") || relative.contains("/tests/")
        default:
            return false
        }
    }

    private func javaArguments(scope: LanguageTestScope, root: URL) -> [String] {
        switch scope {
        case .workspace:
            return ["test"]
        case .file(let url):
            return ["-Dtest=" + url.deletingPathExtension().lastPathComponent, "test"]
        case .testCase(let identifier, _):
            return ["-Dtest=" + normalizedJavaTestIdentifier(identifier), "test"]
        }
    }

    private func gradleArguments(scope: LanguageTestScope, root: URL) throws -> [String] {
        var arguments = ["test"]
        switch scope {
        case .workspace:
            break
        case .file(let url):
            arguments.append(contentsOf: ["--tests", try gradleSelector(for: url, root: root)])
        case .testCase(let identifier, _):
            arguments.append(contentsOf: [
                "--tests",
                normalizedJavaTestIdentifier(identifier).replacingOccurrences(of: "#", with: "."),
            ])
        }
        return arguments
    }

    private func normalizedJavaTestIdentifier(_ identifier: String) -> String {
        identifier.hasSuffix("()") ? String(identifier.dropLast(2)) : identifier
    }

    private func gradleSelector(for url: URL, root: URL) throws -> String {
        _ = try checkedRelativePath(url, root: root)
        return url.deletingPathExtension().lastPathComponent
    }

    private func goArguments(scope: LanguageTestScope, root: URL) throws -> [String] {
        switch scope {
        case .workspace:
            return ["test", "./..."]
        case .file(let url):
            return ["test", try packageArgument(for: url, root: root)]
        case .testCase(let identifier, let fileURL):
            let package: String
            if let fileURL {
                package = try packageArgument(for: fileURL, root: root)
            } else {
                package = "./..."
            }
            var arguments = ["test", package]
            arguments.append(contentsOf: ["-run", "^" + identifier + "$"])
            return arguments
        }
    }

    private func pythonArguments(scope: LanguageTestScope, root: URL) throws -> [String] {
        var arguments = ["-m", "pytest"]
        switch scope {
        case .workspace:
            break
        case .file(let url):
            arguments.append(try checkedRelativePath(url, root: root))
        case .testCase(let identifier, let fileURL):
            if let fileURL {
                arguments.append(try checkedRelativePath(fileURL, root: root) + "::" + identifier)
            } else {
                arguments.append("-k")
                arguments.append(identifier)
            }
        }
        return arguments
    }

    private func nodeArguments(
        framework: StandardTestFramework,
        scope: LanguageTestScope,
        root: URL
    ) throws -> [String] {
        var arguments = ["test"]
        let forwardsArguments = framework == .npm || framework == .pnpm
        if forwardsArguments { arguments.append("--") }
        switch scope {
        case .workspace:
            break
        case .file(let url):
            arguments.append(try checkedRelativePath(url, root: root))
        case .testCase(let identifier, let fileURL):
            if let fileURL { arguments.append(try checkedRelativePath(fileURL, root: root)) }
            switch framework {
            case .bun:
                arguments.append(contentsOf: ["--test-name-pattern", identifier])
            default:
                arguments.append(contentsOf: ["-t", identifier])
            }
        }
        return arguments
    }

    private func rustArguments(scope: LanguageTestScope, root: URL) throws -> [String] {
        switch scope {
        case .workspace:
            return ["test"]
        case .file(let url):
            let relative = try checkedRelativePath(url, root: root)
            if relative.hasPrefix("tests/") {
                return ["test", "--test", url.deletingPathExtension().lastPathComponent]
            }
            return ["test"]
        case .testCase(let identifier, _):
            return ["test", identifier]
        }
    }

    private func packageArgument(for fileURL: URL, root: URL) throws -> String {
        let relative = try checkedRelativePath(fileURL.deletingLastPathComponent(), root: root)
        return relative.isEmpty ? "./..." : "./" + relative
    }

    private func testLabel(scope: LanguageTestScope) -> String {
        switch scope {
        case .workspace: return "All \(descriptor.displayName) Tests"
        case .file(let url): return url.lastPathComponent
        case .testCase(let identifier, _): return identifier
        }
    }

    private func checkedRelativePath(_ url: URL, root: URL) throws -> String {
        let normalized = url.standardizedFileURL
        guard isInsideWorkspace(normalized, root: root) else {
            throw LanguageTestPlanError.fileOutsideWorkspace(normalized)
        }
        return relativePath(normalized, root: root)
    }

    private func isInsideWorkspace(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let path = url.standardizedFileURL.path
        guard path != root.path else { return "" }
        return String(path.dropFirst(root.path.count + 1))
    }
}

package struct LanguageTestProviderRegistry {
    private let providersByID: [String: any LanguageTestProvider]

    package init(providers: [any LanguageTestProvider]) {
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) })
    }

    package static func standard(catalog: LanguageProviderCatalog = .compatibilityFallback) -> Self {
        Self(providers: catalog.descriptors
            .filter { $0.capabilities.contains(.testing) }
            .map(StandardLanguageTestProvider.init))
    }

    package func provider(for fileURL: URL, catalog: LanguageProviderCatalog = .compatibilityFallback) -> (any LanguageTestProvider)? {
        guard let descriptor = catalog.provider(for: fileURL) else { return nil }
        return providersByID[descriptor.id]
    }

    package func provider(id: String) -> (any LanguageTestProvider)? { providersByID[id] }
}
