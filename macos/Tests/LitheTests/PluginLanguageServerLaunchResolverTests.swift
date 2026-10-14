import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

/// Plugin API 2 language servers: the host supplies directories, Rust Core
/// expands the launch templates, and nothing is written into the package.
struct PluginLanguageServerLaunchResolverTests {
    @Test
    func apiLevelTwoDescriptorStartsTheRuntimeAndExpandsTemplates() throws {
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: javaFixtureManifest())
        let server = try #require(descriptor.languageServers.first)

        #expect(server.launch == .runtime(
            tool: "java",
            entryRelativePath: "language-server/plugins/org.eclipse.equinox.launcher.jar",
            packagedRuntime: "runtime/${arch}/bin/java"
        ))
        #expect(server.hostIntegrationID == "jdt")
        // The runtime is the process the host discovers and starts.
        #expect(server.executableNames == ["java"])
        #expect(server.expandsLaunchTemplates)
        #expect(server.packagedRelativePath == nil)
    }

    /// Installed PHP and Go packages declare API 1, whose arguments are
    /// literal. They must keep their existing launch path.
    @Test
    func apiLevelOneDescriptorKeepsLiteralArguments() throws {
        let server = try #require(
            try DeclarativePluginTestSupport.officialDescriptor("PhpSupport").languageServers.first
        )

        #expect(!server.expandsLaunchTemplates)
        #expect(server.arguments == ["--stdio"])
    }

    @Test
    func resolvingCreatesStateOutsideThePackageAndLeavesThePackageUntouched() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root, manifest: "node-runtime.plugin.json", languageID: "fixture")
        let filesBefore = try packageFiles(fixture.source.packageURL)

        let resolved = try fixture.resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)

        let packagePath = fixture.source.packageURL.path
        let architecture = MacPluginLanguageServerLaunchResolver.hostArchitecture
        let stateDirectory = fixture.directories.stateDirectory(pluginID: fixture.source.pluginID, languageID: "fixture")
        let workspaceStateDirectory = fixture.directories.workspaceStateDirectory(
            pluginID: fixture.source.pluginID,
            languageID: "fixture",
            workspaceRootURL: fixture.workspaceURL
        )
        #expect(resolved.arguments == [
            "--max-old-space-size=2048",
            "--require=\(packagePath)/language-server/lib/preload.js",
            "\(packagePath)/language-server/lib/server.js",
            "--stdio",
            "--log-level=info",
            "--storage",
            "\(stateDirectory.path)/storage",
            "--workspace-cache",
            workspaceStateDirectory.path
        ])
        #expect(resolved.initializationOptions == .object([
            "stubs": .array([.string("\(packagePath)/language-server/stubs/\(architecture)")]),
            "telemetry": .bool(false)
        ]))
        #expect(isDirectory(stateDirectory))
        #expect(isDirectory(workspaceStateDirectory))
        #expect(!workspaceStateDirectory.path.hasPrefix(packagePath + "/"))
        #expect(try packageFiles(fixture.source.packageURL) == filesBefore)
    }

    /// The Java plugin's JDT LS files reach the shared JDT launch only through
    /// what the plugin declares; nothing is looked up in the app or on the Mac.
    @Test
    func theJdtIntegrationReceivesExactlyTheDeclaredPackageFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let package = fixture.source.packageURL
        let architecture = MacPluginLanguageServerLaunchResolver.hostArchitecture

        let integration = try #require(try fixture.resolver.hostIntegration(for: fixture.source))
        let resources = try MacJdtLaunchResources().resources(from: integration, javaRuntimes: [])

        #expect(integration.id == MacJdtHostIntegration.integrationID)
        #expect(resources.launcherJarURL == package.appendingPathComponent(
            "language-server/plugins/org.eclipse.equinox.launcher.jar"
        ))
        // The packaged directory itself: Rust Core makes the writable copy.
        #expect(resources.configurationDirectoryURL.path
            == package.appendingPathComponent("language-server/configuration/\(architecture)").path)
        #expect(resources.lombokAgentURL == package.appendingPathComponent("language-server/lombok/lombok.jar"))
        // Declared directory order first, then file name; non-JAR files are ignored.
        #expect(resources.javaExtensionBundleURLs.map(\.lastPathComponent) == [
            "com.microsoft.java.debug.plugin.jar", "a-extension.jar", "b-extension.jar"
        ])
        #expect(resources.javaTestRunnerURL == package.appendingPathComponent(
            "language-server/java-test/runner/runner.jar"
        ))
        // Locating the files must not create plugin state.
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.rootURL.path))
    }

    @Test
    func theGenericLaunchOfTheJavaPluginStartsItsEntryWithoutStateDirectories() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)

        let resolved = try fixture.resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)

        #expect(resolved.arguments == [
            "-Dfile.encoding=UTF-8",
            "-jar",
            fixture.source.packageURL.appendingPathComponent(
                "language-server/plugins/org.eclipse.equinox.launcher.jar"
            ).path
        ])
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.rootURL.path))
    }

    /// What the user stored for a setting reaches the server command line, and
    /// a boolean setting stays a boolean in the initialization options.
    @Test
    func storedPluginSettingsReachTheLaunchAndUnacceptableOnesFallBackToDefaults() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = InMemoryPluginSettings()
        let fixture = try makeFixture(
            root: root,
            manifest: "node-runtime.plugin.json",
            languageID: "fixture",
            settings: settings
        )
        let pluginID = fixture.source.pluginID
        settings.setValue(.integer(4096), forSetting: "heapMB", plugin: pluginID)
        settings.setValue(.string("debug"), forSetting: "logLevel", plugin: pluginID)
        settings.setValue(.bool(true), forSetting: "telemetry", plugin: pluginID)

        let resolved = try fixture.resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)

        #expect(resolved.arguments.first == "--max-old-space-size=4096")
        #expect(resolved.arguments.contains("--log-level=debug"))
        guard case .object(let options)? = resolved.initializationOptions else {
            Issue.record("The launch has no initialization options")
            return
        }
        #expect(options["telemetry"] == .bool(true))

        // A stored value the declaration no longer accepts never fails the launch.
        settings.setValue(.integer(1), forSetting: "heapMB", plugin: pluginID)
        settings.setValue(.string("verbose"), forSetting: "logLevel", plugin: pluginID)
        let fallback = try fixture.resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)
        #expect(fallback.arguments.first == "--max-old-space-size=2048")
        #expect(fallback.arguments.contains("--log-level=info"))
    }

    @Test
    func theDescriptorListsTheDeclaredSettingsAndTheirAcceptedValues() throws {
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: fixtureManifest("node-runtime.plugin.json")
        )

        #expect(descriptor.settings.map(\.id) == ["heapMB", "logLevel", "telemetry"])
        let heap = try #require(descriptor.settings.first)
        #expect(heap.kind == .integer(minimum: 512, maximum: 8192, unit: "MB"))
        #expect(heap.defaultValue == .integer(2048))
        #expect(heap.accepts(.integer(512)) && heap.accepts(.integer(8192)))
        #expect(!heap.accepts(.integer(511)) && !heap.accepts(.string("2048")))
        #expect(heap.effectiveValue(stored: .integer(99999)) == .integer(2048))
        #expect(heap.effectiveValue(stored: .integer(1024)) == .integer(1024))
        let level = descriptor.settings[1]
        #expect(level.accepts(.string("debug")) && !level.accepts(.string("trace")))
        #expect(descriptor.settings[2].accepts(.bool(false)) && !descriptor.settings[2].accepts(.integer(0)))
    }

    @Test
    func twoWorkspacesNeverShareAWorkspaceStateDirectory() throws {
        let directories = MacPluginStateDirectories(rootURL: temporaryRoot())
        let first = directories.workspaceStateDirectory(
            pluginID: "dev.example.plugin",
            languageID: "java",
            workspaceRootURL: URL(fileURLWithPath: "/projects/one")
        )
        let second = directories.workspaceStateDirectory(
            pluginID: "dev.example.plugin",
            languageID: "java",
            workspaceRootURL: URL(fileURLWithPath: "/projects/two")
        )

        #expect(first != second)
        #expect(!first.path.contains("projects"))
    }

    @Test
    func aMissingPackageFileStopsTheLaunchBeforeAnyStateIsCreated() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        try FileManager.default.removeItem(
            at: fixture.source.packageURL.appendingPathComponent("language-server/lombok/lombok.jar")
        )

        #expect(throws: MacPluginLanguageServerLaunchResolver.ResolutionError.missingPackagePath(
            "language-server/lombok/lombok.jar"
        )) {
            try fixture.resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.rootURL.path))
    }

    /// A link would let a package hand the server a file from outside its own
    /// signed contents.
    @Test
    func aSymbolicLinkInsideThePackageIsRefused() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let lombok = fixture.source.packageURL.appendingPathComponent("language-server/lombok/lombok.jar")
        let outside = root.appendingPathComponent("outside.jar")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: lombok)
        try FileManager.default.createSymbolicLink(at: lombok, withDestinationURL: outside)

        #expect(throws: MacPluginLanguageServerLaunchResolver.ResolutionError.packagePathOutsidePackage(
            "language-server/lombok/lombok.jar"
        )) {
            try fixture.resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)
        }
    }

    /// The plugin ships its own runtime, so the host is told where it is
    /// inside the package instead of looking for `java` on the machine.
    @Test
    func theRuntimeShippedByThePluginIsPinnedInsideItsPackage() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)

        let probe = try fixture.resolver.executableProbe(for: fixture.source)

        #expect(probe.validationArguments.isEmpty)
        #expect(probe.versionRequirement == nil)
        #expect(probe.packagedRuntimeURL == fixture.source.packageURL.appendingPathComponent(
            "runtime/\(MacPluginLanguageServerLaunchResolver.hostArchitecture)/bin/java"
        ).standardizedFileURL)
        // Expanding the probe needs no workspace and must not create state.
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.rootURL.path))
    }

    /// A JDK older than the plugin requires must not be offered, even when it
    /// is first on PATH; the first runtime that qualifies is used.
    @MainActor
    @Test
    func runtimeCandidatesBelowTheMinimumVersionAreNotUsed() async {
        let old = URL(fileURLWithPath: "/jdks/17/bin/java")
        let stub = URL(fileURLWithPath: "/usr/bin/java")
        let current = URL(fileURLWithPath: "/jdks/21/bin/java")
        let runner = VersionProbeRunner(outputs: [
            old.path: (0, "openjdk 17.0.11 2024-04-16"),
            stub.path: (1, "Unable to locate a Java Runtime."),
            current.path: (0, "openjdk 21.0.12 2026-07-15 LTS")
        ])
        let service = LanguageServerToolService(
            runtimeService: FixedLanguageToolRuntime(candidates: ["java": [old, stub, current]]),
            commandRunner: runner,
            settingsStore: MemoryLanguageToolSettings(),
            versionChecker: DeclarativePluginTestSupport.operations
        )
        let descriptor = javaRuntimeDescriptor()

        // Nothing is offered before the probe ran.
        #expect(service.candidates(for: descriptor).isEmpty)
        #expect(service.needsCandidateValidation(for: descriptor))

        let usable = await service.refreshCandidates(for: descriptor)

        #expect(usable.map(\.executableURL) == [current])
        #expect(service.executableURL(for: descriptor) == current)
        #expect(service.executableVerificationState(for: descriptor) == .executableVerified)
        #expect(runner.arguments.allSatisfy { $0 == ["--version"] })
    }

    @MainActor
    @Test
    func aCustomRuntimeBelowTheMinimumVersionIsRejectedWithTheReason() async {
        let old = URL(fileURLWithPath: "/jdks/17/bin/java")
        let service = LanguageServerToolService(
            runtimeService: FixedLanguageToolRuntime(candidates: [:]),
            commandRunner: VersionProbeRunner(outputs: [old.path: (0, "openjdk 17.0.11 2024-04-16")]),
            settingsStore: MemoryLanguageToolSettings(),
            versionChecker: DeclarativePluginTestSupport.operations
        )

        await #expect(throws: LanguageServerToolConfigurationError.executableValidationFailed(
            path: old.path,
            message: "java 17.0.11 is older than the required 21."
        )) {
            try await service.setCustomExecutablePath(old.path, for: javaRuntimeDescriptor())
        }
    }

    /// Template arguments must never reach a process unexpanded.
    @MainActor
    @Test
    func aTemplatedLaunchWithoutAResolverIsUnavailable() {
        let source = DeclarativeLanguageServerLaunchSource(
            pluginID: "dev.example.plugin",
            languageID: "fixture",
            manifest: Data(),
            packageURL: URL(fileURLWithPath: "/plugins/fixture")
        )
        let launch = LanguageServerLaunchDescriptor(
            executableNames: ["sh"],
            arguments: ["${pluginDir}/server"],
            launchSource: source
        )
        let runtime = StdioLanguageProviderRuntime(
            descriptor: LanguageProviderDescriptor(
                id: "fixture",
                displayName: "Fixture",
                fileExtensions: ["fixture"],
                capabilities: .languageServer,
                activationPolicy: .onDemand,
                languageServerLaunch: launch
            ),
            runtimeService: FixedLanguageToolRuntime(candidates: [:]),
            languageServerLaunch: launch,
            languageServerCore: RustCoreBridge()
        )

        #expect(runtime.makeLanguageServerSession() == nil)
        #expect(runtime.unavailableToolingMessage?.contains("launch plan") == true)
    }

    @MainActor
    @Test
    func aFailedLaunchPlanFailsTheSessionWithoutStartingAProcess() {
        let session = LanguageServerRuntimeSession(
            providerID: "fixture",
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["${pluginDir}/server"],
            environment: [:],
            launchResolver: { _ in
                throw DeclarativePluginRejection(
                    code: "plugin.launch.invalidRequest",
                    message: "The launch request has no usable pluginDirectory."
                )
            },
            core: RustCoreBridge()
        )
        var states: [LanguageServerSessionState] = []
        session.onStateChange = { states.append($0) }

        #expect(throws: LanguageServerSessionStartError.self) {
            try session.start(rootURL: URL(fileURLWithPath: "/projects/one"), workspaceFingerprint: nil)
        }
        #expect(!session.isRunning)
        guard case .failed(let failure)? = states.last else {
            Issue.record("The session did not report a failure: \(states)")
            return
        }
        #expect(failure.code == "plugin.launch.invalidRequest")
    }

    // MARK: Fixtures

    private struct Fixture {
        let source: DeclarativeLanguageServerLaunchSource
        let directories: MacPluginStateDirectories
        let resolver: MacPluginLanguageServerLaunchResolver
        let workspaceURL: URL
    }

    /// Files each fixture manifest points at. A trailing `/` marks a directory.
    private func declaredFiles(_ manifest: String) -> [String] {
        let architecture = MacPluginLanguageServerLaunchResolver.hostArchitecture
        return manifest == "node-runtime.plugin.json"
            ? [
                "language-server/lib/server.js",
                "language-server/lib/preload.js",
                "language-server/stubs/\(architecture)/"
            ]
            : [
                "language-server/lombok/lombok.jar",
                "language-server/plugins/org.eclipse.equinox.launcher.jar",
                "language-server/configuration/\(architecture)/config.ini",
                "language-server/java-debug/com.microsoft.java.debug.plugin.jar",
                "language-server/java-debug/LICENSE.txt",
                "language-server/java-test/extensions/b-extension.jar",
                "language-server/java-test/extensions/a-extension.jar",
                "language-server/java-test/runner/runner.jar",
                "runtime/\(architecture)/bin/java"
            ]
    }

    private func makeFixture(
        root: URL,
        manifest: String = "java-support.plugin.json",
        languageID: String = "java",
        settings: any PluginSettingsStoring = InMemoryPluginSettings()
    ) throws -> Fixture {
        let operations = DeclarativePluginTestSupport.operations
        let descriptor = try operations.validate(manifest: fixtureManifest(manifest))
        let packageURL = root.appendingPathComponent("package", isDirectory: true)
        for relativePath in declaredFiles(manifest) {
            let url = packageURL.appendingPathComponent(relativePath)
            if relativePath.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("file".utf8).write(to: url)
        }
        let directories = MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true))
        return Fixture(
            source: DeclarativeLanguageServerLaunchSource(
                pluginID: descriptor.id.rawValue,
                languageID: languageID,
                manifest: descriptor.normalizedManifest,
                packageURL: packageURL
            ),
            directories: directories,
            resolver: MacPluginLanguageServerLaunchResolver(
                planner: operations,
                directories: directories,
                settings: settings
            ),
            workspaceURL: root.appendingPathComponent("workspace", isDirectory: true)
        )
    }

    private func javaRuntimeDescriptor() -> LanguageProviderDescriptor {
        LanguageProviderDescriptor(
            id: "java",
            displayName: "Java",
            fileExtensions: ["java"],
            capabilities: .languageServer,
            activationPolicy: .onDemand,
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["java"],
                executableVersionRequirement: LanguageServerExecutableVersionRequirement(
                    tool: "java",
                    minimumVersion: "21",
                    probeArguments: ["--version"]
                )
            )
        )
    }

    private func javaFixtureManifest() throws -> Data {
        try fixtureManifest("java-support.plugin.json")
    }

    private func fixtureManifest(_ name: String) throws -> Data {
        try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures")
            .appendingPathComponent(name))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-plugin-launch-\(UUID().uuidString)", isDirectory: true)
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func packageFiles(_ packageURL: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: packageURL.path).sorted()
    }
}

@MainActor
private final class FixedLanguageToolRuntime: LanguageToolRuntimePort {
    private let candidates: [String: [URL]]

    init(candidates: [String: [URL]]) {
        self.candidates = candidates
    }

    func executableOnPath(_ name: String) -> URL? { URL(fileURLWithPath: "/bin/\(name)") }
    func executableURL(at path: String) -> URL? { URL(fileURLWithPath: path) }
    func executableCandidates(_ command: String) -> [RuntimeToolCandidate] {
        (candidates[command] ?? []).map {
            RuntimeToolCandidate(command: command, executableURL: $0, source: .path)
        }
    }
    func languageToolProcessEnvironment(runtimeTools: [String]) -> [String: String] { [:] }
    func missingLanguageToolMessage(_ name: String) -> String { "\(name) is missing." }
}

/// Answers a version probe per executable without starting a process.
private final class VersionProbeRunner: LanguageToolCommandRunning, @unchecked Sendable {
    private let outputs: [String: (exitCode: Int32, output: String)]
    private let lock = NSLock()
    private var recordedArguments: [[String]] = []

    init(outputs: [String: (Int32, String)]) {
        self.outputs = outputs.mapValues { (exitCode: $0.0, output: $0.1) }
    }

    var arguments: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedArguments
    }

    func runLanguageToolCommand(
        operationID _: String,
        executableURL: URL,
        arguments: [String],
        environment _: [String: String],
        timeoutMilliseconds _: Int
    ) -> LanguageToolCommandResult {
        lock.lock()
        recordedArguments.append(arguments)
        lock.unlock()
        let result = outputs[executableURL.path] ?? (exitCode: 127, output: "")
        return LanguageToolCommandResult(output: result.output, exitCode: result.exitCode)
    }
}

private final class MemoryLanguageToolSettings: LanguageToolSettingsStoring {
    private var paths: [String: String] = [:]
    func loadLanguageToolExecutablePaths() -> [String: String] { paths }
    func saveLanguageToolExecutablePaths(_ paths: [String: String]) { self.paths = paths }
}
