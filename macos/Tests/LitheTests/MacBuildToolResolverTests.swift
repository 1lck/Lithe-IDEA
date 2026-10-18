import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Build tool resolver version output")
@MainActor
struct MacBuildToolResolverTests {
    @Test
    func languageImportDiscoversWrapperWithoutExecutingItOrRuntimeProbes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("unexpected-execution")
        let executable = root.appendingPathComponent("wrapper")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore())
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage())
        let invocation = BuildInvocation(
            executables: [.projectFile(path: "wrapper", requires: [])],
            runtimeDependencies: [.init(id: "java", hostManaged: true, minimumVersion: "8", executables: [], versionArguments: ["-version"])],
            versionArguments: ["--version"], minimumVersion: "1"
        )
        #expect(resolver.languageImportExecutable(invocation, workspaceURL: root) == executable.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test
    func javaVersionProbeForwardsStderrToVersionCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/java")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A Java 8-shaped executable rejects --version and prints only to stderr.
        // The resolver owns a bounded process request and runs it off the main actor.
        let script = """
        #!/bin/sh
        [ "$#" -eq 1 ] && [ "$1" = '-version' ] || exit 2
        printf '%s\\n' 'Picked up JAVA_TOOL_OPTIONS: -Xmx512m' 'java version "1.8.0_452"' >&2
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runtime = ProjectRuntimeService(
            runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore()
        )
        let resolver = MacBuildToolResolver(
            runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage()
        )
        // Explicit candidates isolate the resolver's probe/capture boundary from
        // runtime selection; Core's host-managed arguments have their own regression.
        let invocation = BuildInvocation(
            executables: [.runtime("java")],
            environmentInputs: ["FIXTURE_JDK"],
            runtimeDependencies: [.init(
                id: "java", hostManaged: false, minimumVersion: "8",
                executables: [.environment(variable: "FIXTURE_JDK", path: "bin/java")],
                versionArguments: ["-version"]
            )]
        )
        let resolved = try await resolver.resolve(
            invocation, displayName: "Fixture", workspaceURL: root
        ) { runtimeID, output in
            #expect(runtimeID == "java")
            #expect(output.contains("Picked up JAVA_TOOL_OPTIONS: -Xmx512m"))
            #expect(output.contains("java version \"1.8.0_452\""))
            return BuildVersionCheck(satisfied: output.contains("1.8.0_452"), version: "8.0")
        }
        #expect(resolved.executableURL == executable)
        #expect(!resolved.executesProjectCode)
    }

    /// A custom runtime may live in the project, for example a virtual
    /// environment. Core accepts a `projectFile` candidate; the resolver must
    /// use it without probing, because probing would run repository code.
    @Test
    func projectLocalRuntimeCandidateResolvesWithoutProbing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(".venv/bin/python")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let marker = root.appendingPathComponent("probed")
        let script = """
        #!/bin/sh
        touch "\(marker.path)"
        exit 0
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runtime = ProjectRuntimeService(
            runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore()
        )
        let resolver = MacBuildToolResolver(
            runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage()
        )
        let invocation = BuildInvocation(
            executables: [.runtime("python")],
            runtimeDependencies: [.init(
                id: "python", hostManaged: false, minimumVersion: "3",
                executables: [.projectFile(path: ".venv/bin/python", requires: [])],
                versionArguments: ["--version"]
            )]
        )
        let resolved = try await resolver.resolve(
            invocation, displayName: "Fixture", workspaceURL: root
        ) { _, _ in
            Issue.record("A project-local runtime must not be probed")
            return BuildVersionCheck(satisfied: false, version: nil)
        }
        #expect(resolved.executableURL == executable.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

private struct BuildProbeRuntimeLocator: RuntimeLocator {
    let home: URL
    func environment() -> [String: String] { ["FIXTURE_JDK": home.path] }
    func discover() -> RuntimeDiscoveryResult { .init(javaRuntimes: [], mavenRuntimes: []) }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func systemMavenExecutable() -> URL? { nil }
    func mavenExecutable(forHomePath path: String) -> URL? { nil }
    func mavenRuntime(at executableURL: URL) -> MavenRuntimeCandidate? { nil }
}

private struct BuildProbeEmptyStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
}
