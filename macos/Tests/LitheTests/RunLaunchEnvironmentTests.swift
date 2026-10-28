import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

/// A Lithe opened from Finder inherits launchd's minimal `PATH`, while the
/// tools it resolved may live in Homebrew or a Node version manager directory.
/// These tests protect the launch environment that makes `#!/usr/bin/env node`
/// launchers start the interpreter Lithe found.
@Suite("Run launch environment")
struct RunLaunchEnvironmentTests {
    private let projectURL = URL(fileURLWithPath: "/fixture-project", isDirectory: true)

    @Test
    func guiLaunchPathReachesTheDiscoveredNodeInterpreter() {
        let environment = RunLaunchEnvironment.augmenting(
            ["PATH": "/usr/bin:/bin"],
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            nodeCandidates: [
                RuntimeToolCandidate(
                    command: "node",
                    executableURL: URL(fileURLWithPath: "/Users/fixture/.local/share/fnm/aliases/default/bin/node"),
                    source: .environment
                )
            ],
            projectURL: projectURL
        )

        #expect(environment["PATH"] == "/usr/bin:/bin:/Users/fixture/.local/share/fnm/aliases/default/bin:/opt/homebrew/bin")
    }

    @Test
    func projectProvidedNodeCannotCaptureTheLaunchedScript() {
        let projectNode = RuntimeToolCandidate(
            command: "node",
            executableURL: projectURL.appendingPathComponent(".lithe/bin/node"),
            source: .project
        )
        let homebrewNode = RuntimeToolCandidate(
            command: "node",
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            source: .homebrew
        )

        let withFallback = RunLaunchEnvironment.augmenting(
            ["PATH": "/usr/bin:/bin"],
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            nodeCandidates: [projectNode, homebrewNode],
            projectURL: projectURL
        )
        let projectNodeOnly = RunLaunchEnvironment.augmenting(
            ["PATH": "/usr/bin:/bin"],
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            nodeCandidates: [projectNode],
            projectURL: projectURL
        )

        #expect(withFallback["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin")
        #expect(projectNodeOnly["PATH"] == "/usr/bin:/bin:/opt/homebrew/bin")
    }

    @Test
    func projectWrapperDoesNotPutTheRepositoryOnTheLaunchPath() {
        let environment = RunLaunchEnvironment.augmenting(
            ["PATH": "/usr/bin:/bin"],
            executableURL: projectURL.appendingPathComponent("mvnw"),
            nodeCandidates: [],
            projectURL: projectURL
        )

        #expect(environment["PATH"] == "/usr/bin:/bin")
    }

    @Test
    func existingEntriesKeepTheirOrderAndAreNotDuplicated() {
        let environment = RunLaunchEnvironment.augmenting(
            ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"],
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            nodeCandidates: [
                RuntimeToolCandidate(
                    command: "node",
                    executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
                    source: .homebrew
                )
            ],
            projectURL: projectURL
        )

        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test
    func explicitPathEntriesKeepTheirPriority() {
        let environment = RunLaunchEnvironment.augmenting(
            ["PATH": "/custom/node/bin:/usr/bin:/bin"],
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            nodeCandidates: [
                RuntimeToolCandidate(
                    command: "node",
                    executableURL: URL(fileURLWithPath: "/fixture-node/bin/node"),
                    source: .environment
                )
            ],
            projectURL: projectURL
        )

        #expect(environment["PATH"] == "/custom/node/bin:/usr/bin:/bin:/fixture-node/bin:/opt/homebrew/bin")
    }

    @Test(arguments: [nil, "", "/explicit/bin"] as [String?])
    func missingPathUsesOnlyTheInjectedSystemDefault(path: String?) {
        var original = ["HOME": "/Users/fixture"]
        original["PATH"] = path
        let environment = RunLaunchEnvironment.augmenting(
            original,
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/pnpm"),
            nodeCandidates: [],
            projectURL: projectURL,
            defaultSearchPath: "/fixture-system/bin:/fixture-system/sbin"
        )

        let prefix = path == nil ? "/fixture-system/bin:/fixture-system/sbin:" : (path == "" ? "" : path! + ":")
        #expect(environment["PATH"] == prefix + "/opt/homebrew/bin")
        #expect(environment["HOME"] == "/Users/fixture")
    }

    @Test
    @MainActor
    func resolverAppliesTheLaunchDirectoriesToCommandsResolvedFromPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-run-launch-path-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let tools = root.appendingPathComponent("tools/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pnpm = tools.appendingPathComponent("pnpm")
        try Data("#!/bin/sh\n".utf8).write(to: pnpm)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pnpm.path)

        let service = ProjectRuntimeService(
            runtimeLocator: RunLaunchPathRuntimeLocator(
                environmentValues: ["PATH": "\(tools.path):/usr/bin:/bin"],
                executablePath: pnpm.path
            ),
            store: RunLaunchPathStore(),
            toolDiscovery: RunLaunchPathToolDiscovery(node: URL(fileURLWithPath: "/fixture-node/bin/node"))
        )
        let plan = SharedLaunchPlan(
            executable: .command("pnpm"),
            arguments: ["run", "clean"],
            workingDirectory: "."
        )

        let resolved = try RunExecutableResolver(runtimeService: service)
            .resolve(plan, projectURL: project, options: RunOptions())

        #expect(resolved.executableURL == pnpm)
        #expect(resolved.environment["PATH"] == "\(tools.path):/usr/bin:/bin:/fixture-node/bin")
    }

    @Test(arguments: [false, true])
    @MainActor
    func resolverAppliesTheInterpreterDirectoryToNodeToolchains(missingPath: Bool) throws {
        let service = ProjectRuntimeService(
            runtimeLocator: RunLaunchPathRuntimeLocator(
                environmentValues: missingPath ? [:] : ["PATH": "/usr/bin:/bin"],
                executablePath: "/unused"
            ),
            store: RunLaunchPathStore(),
            toolDiscovery: RunLaunchPathToolDiscovery(node: URL(fileURLWithPath: "/fixture-node/bin/node"))
        )
        let plan = SharedLaunchPlan(
            executable: .toolchain("project-node"),
            arguments: ["script.js"],
            workingDirectory: "."
        )

        let resolved = try RunExecutableResolver(runtimeService: service)
            .resolve(plan, projectURL: projectURL, options: RunOptions())

        #expect(resolved.executableURL.path == "/fixture-node/bin/node")
        #expect(resolved.environment["PATH"] == (missingPath ? "/fixture-system/bin" : "/usr/bin:/bin") + ":/fixture-node/bin")
        #expect(service.processEnvironment()["PATH"] == (missingPath ? nil : "/usr/bin:/bin"),
            "Run fallback must not change the environment of terminals or language servers")
    }
}

private struct RunLaunchPathRuntimeLocator: RuntimeLocator {
    let environmentValues: [String: String]
    let executablePath: String

    func environment() -> [String: String] { environmentValues }
    func defaultExecutableSearchPath() -> String? { "/fixture-system/bin" }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: [], mavenRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { url.standardizedFileURL.path == executablePath }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}

private final class RunLaunchPathStore: KeyValueStore {
    private var values: [String: Any] = [:]

    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private struct RunLaunchPathToolDiscovery: RuntimeToolDiscovery {
    let node: URL

    func candidates(for command: String, projectURL: URL?, environment: [String: String]) -> [RuntimeToolCandidate] {
        guard command == "node" else { return [] }
        return [
            RuntimeToolCandidate(command: "node", executableURL: node, source: .environment)
        ]
    }

    func guidance(
        for command: String,
        projectURL: URL?,
        environment: [String: String]
    ) -> RuntimeToolGuidance {
        DefaultRuntimeToolDiscovery().guidance(
            for: command,
            projectURL: projectURL,
            environment: environment
        )
    }
}
