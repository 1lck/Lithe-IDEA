import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Build tool resolver version output")
@MainActor
struct MacBuildToolResolverTests {
    @Test
    func sharedResolverUsesInjectedEnvironmentCommandAndRuntimeDiscovery() {
        let custom = URL(fileURLWithPath: "/tools/build")
        let resolver = ExecutableCandidateResolver(fileExists: { _ in true }, isExecutable: { $0 == custom },
            commands: { $0 == "build" ? [custom] : [] }, runtimes: { $0 == "build" ? custom : nil })
        let workspace = URL(fileURLWithPath: "/workspace")
        for candidate in [ExecutableCandidate.command("build"), .runtime("build"), .environment(variable: "BUILD_HOME", path: "build")] {
            guard case .resolved(let result) = resolver.resolve(candidate, workspaceURL: workspace,
                environment: ["BUILD_HOME": "/tools"], environmentInputs: ["BUILD_HOME"]) else {
                Issue.record("The injected source must resolve")
                continue
            }
            #expect(result.first?.url == custom)
        }
        #expect(resolver.resolve(.environment(variable: "BUILD_HOME", path: "build"), workspaceURL: workspace,
            environment: ["BUILD_HOME": "/tools"], environmentInputs: []) == .skip)
    }
    @Test(arguments: ["missing", "non-executable", "old", "directory"])
    func unusableConfiguredPathNeverFallsBackToAvailableWrapper(_ failure: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configured = root.appendingPathComponent("configured")
        if failure == "directory" {
            try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        } else if failure != "missing" {
            try Data("#!/bin/sh\nprintf 'fixture 1.0\\n'\n".utf8).write(to: configured)
            try FileManager.default.setAttributes([.posixPermissions: failure == "old" ? 0o755 : 0o644], ofItemAtPath: configured.path)
        }
        let fallback = root.appendingPathComponent("wrapper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fallback)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root))
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage())
        let invocation = BuildInvocation(
            executables: [.setting(id: "toolPath", path: configured.path), .projectFile(path: "wrapper", requires: [])], versionArguments: ["--version"],
            minimumVersion: "2"
        )
        await #expect(throws: BuildToolResolutionError.self) {
            try await resolver.resolve(invocation, displayName: "Fixture", workspaceURL: root) { _, _ in
                BuildVersionCheck(satisfied: false, version: "1.0")
            }
        }
    }

    @Test
    func customRuntimeUsesTheSharedSettingCandidateAndDoesNotFallBack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root))
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage())
        let invocation = BuildInvocation(executables: [.runtime("custom")], runtimeDependencies: [
            .init(id: "custom", hostManaged: false, executables: [.setting(id: "runtimePath", path: root.appendingPathComponent("missing").path), .command("sh")])
        ])
        do {
            _ = try await resolver.resolve(invocation, displayName: "Fixture", workspaceURL: root) { _, _ in
                BuildVersionCheck(satisfied: true, version: nil)
            }
            Issue.record("An explicit runtime failure must terminate discovery")
        } catch let error as BuildToolResolutionError { #expect(error.terminal) }
    }

    @Test
    func customRuntimeProbeAndExecutionUseTheSameSiblingHelper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("custom runtime/runtime")
        let helper = executable.deletingLastPathComponent().appendingPathComponent("fixture-helper")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (url, script) in [(executable, "#!/bin/sh\nexec fixture-helper\n"),
                              (helper, "#!/bin/sh\nprintf 'fixture 2.0\\n'\n")] {
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // The injected environment has no PATH entry for the helper. Only the
        // candidate-specific environment can make this version probe succeed.
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root))
        let runner = MacProcessRunner()
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: runner, fileStorage: MacFileStorage())
        let invocation = BuildInvocation(executables: [.runtime("custom")], runtimeDependencies: [
            .init(id: "custom", hostManaged: false, minimumVersion: "2",
                  executables: [.setting(id: "runtimePath", path: executable.path)], versionArguments: ["--version"])
        ])
        let resolved = try await resolver.resolve(invocation, displayName: "Fixture", workspaceURL: root) { id, output in
            #expect(id == "custom")
            #expect(output == "fixture 2.0\n")
            return BuildVersionCheck(satisfied: output == "fixture 2.0\n", version: "2.0")
        }
        #expect(resolved.environment["PATH"] == executable.deletingLastPathComponent().path)
        let request = ProcessRequest(executablePath: resolved.executableURL.path, arguments: [],
                                     environment: resolved.environment, timeoutMilliseconds: 2_000)
        let output = await Task.detached { runner.run(request).output }.value
        #expect(output == "fixture 2.0\n")
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
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root))
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
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root))
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

    /// A tool definition's selection runs with the caller's whole environment,
    /// but the provider learns only what the selection added. Treating every
    /// inherited variable as contributed made Core reject the hints as too large.
    @Test
    func toolchainSelectionContributesOnlyItsExportsToTheProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("jdk")
        let executable = home.appendingPathComponent("bin/java")
        let base = ["PATH": "/usr/bin:/bin", "FIXTURE_SECRET": "test-only-secret", "SHELL": "/bin/zsh"]
        let exports = ["FIXTURE_HOME": home.path, "PATH": home.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
        let selection = ResolvedDefinedToolchain(
            executable: executable, environment: base.merging(exports) { _, new in new },
            projectCode: true, version: "21", home: home.path, exports: exports
        )
        let runtime = ProjectRuntimeService(runtimeLocator: FixedEnvironmentRuntimeLocator(values: base))
        let resolver = MacBuildToolResolver(
            runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage(),
            definedTools: FixedDefinedTools(selection: selection)
        )
        let invocation = BuildInvocation(executables: [.toolchain(id: "fixture-tool", root: ".")])
        let resolved = try await resolver.resolve(invocation, displayName: "Fixture", workspaceURL: root) { _, _ in
            Issue.record("A toolchain that executes project code must not be probed")
            return BuildVersionCheck(satisfied: false, version: nil)
        }
        #expect(resolved.executableURL == executable)
        #expect(resolved.executesProjectCode)
        #expect(resolved.environment["FIXTURE_SECRET"] == "test-only-secret")
        #expect(resolved.environment["FIXTURE_HOME"] == home.path)
        #expect(Set(resolved.providerEnvironment.keys) == ["PATH", "FIXTURE_HOME"])
        #expect(resolved.providerEnvironment["PATH"]?.hasPrefix(home.appendingPathComponent("bin").path + ":") == true)
    }
}

private struct FixedEnvironmentRuntimeLocator: RuntimeLocator {
    let values: [String: String]
    func environment() -> [String: String] { values }
    func isExecutable(at url: URL) -> Bool { false }
}

private final class FixedDefinedTools: DefinedToolchainResolving {
    private let selection: ResolvedDefinedToolchain
    init(selection: ResolvedDefinedToolchain) { self.selection = selection }
    func resolve(tool _: String, directory _: String, workspace _: URL, environment _: [String: String],
                 minimumVersion _: String?, projectCodeAllowed _: Bool,
                 fixed _: FixedToolchainSelection?, use _: DefinedToolchainUse, consumerID _: String?) async throws -> ResolvedDefinedToolchain? {
        selection
    }
    func resolve(tool _: String, directory _: String, workspace _: URL, environment _: [String: String],
                 minimumVersion _: String?, projectCodeAllowed _: Bool) async throws -> ResolvedDefinedToolchain? {
        selection
    }
}

private struct BuildProbeRuntimeLocator: RuntimeLocator {
    let home: URL
    func environment() -> [String: String] { ["FIXTURE_JDK": home.path] }
    func isExecutable(at url: URL) -> Bool { false }
}

struct CanonicalToolchainRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/usr/bin:/bin", "FIXTURE_SECRET": "test-only-secret"] }
    func isExecutable(at url: URL) -> Bool { FileManager.default.isExecutableFile(atPath: url.path) }
}

private final class ToolchainPreferenceStore: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
