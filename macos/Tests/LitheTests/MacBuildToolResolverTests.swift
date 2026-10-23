import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Build tool resolver version output")
@MainActor
struct MacBuildToolResolverTests {
    @Test
    func emptySettingSkipsToWrapperAndPassiveSelectionNeverProbes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("unexpected-probe")
        let wrapper = root.appendingPathComponent("wrapper")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore())
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage())
        let invocation = BuildInvocation(executables: [.setting(id: "toolPath", path: nil), .projectFile(path: "wrapper", requires: [])],
                                         versionArguments: ["--version"], minimumVersion: "2")
        #expect(resolver.languageImportExecutable(invocation, workspaceURL: root) == wrapper)
        let result = try await resolver.resolve(invocation, displayName: "Fixture", workspaceURL: root) { _, _ in
            Issue.record("A wrapper must not be probed")
            return BuildVersionCheck(satisfied: false, version: nil)
        }
        #expect(result.executableURL == wrapper)
        #expect(result.executesProjectCode)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let invalid = BuildInvocation(executables: [.setting(id: "toolPath", path: root.appendingPathComponent("missing").path), .projectFile(path: "wrapper", requires: [])])
        #expect(resolver.languageImportExecutable(invalid, workspaceURL: root) == nil)
    }

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
    @Test
    func configuredPathWithSpacesWinsOverDiscoveryAndSuppliesItsDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("custom tools/build-tool")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf 'fixture 2.0\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore())
        let resolver = MacBuildToolResolver(runtime: runtime, processRunner: MacProcessRunner(), fileStorage: MacFileStorage())
        let invocation = BuildInvocation(
            executables: [.setting(id: "toolPath", path: executable.path), .command("unavailable")], versionArguments: ["--version"],
            minimumVersion: "2"
        )
        let resolved = try await resolver.resolve(invocation, displayName: "Fixture", workspaceURL: root) { _, output in
            BuildVersionCheck(satisfied: output.contains("fixture 2.0"), version: "2.0")
        }
        #expect(resolved.executableURL == executable)
        #expect(resolved.environment["PATH"]?.hasPrefix(executable.deletingLastPathComponent().path + ":") == true)
        #expect(resolver.languageImportExecutable(invocation, workspaceURL: root) == executable)
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
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore())
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
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore())
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
        let runtime = ProjectRuntimeService(runtimeLocator: BuildProbeRuntimeLocator(home: root), store: BuildProbeEmptyStore())
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
