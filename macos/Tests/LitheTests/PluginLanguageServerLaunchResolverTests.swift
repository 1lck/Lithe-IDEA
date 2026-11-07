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
        let descriptor = try DeclarativePluginTestSupport.operations.validate(
            manifest: fixtureManifest("node-runtime.plugin.json")
        )
        let server = try #require(descriptor.languageServers.first)

        #expect(server.launch == .runtime(
            tool: "node",
            entryRelativePath: "language-server/lib/server.js",
            packagedRuntime: nil
        ))
        // The runtime is the process the host discovers and starts.
        #expect(server.executableNames == ["node"])
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

    @Test
    func unavailableLogStorageOnlyRejectsTemplatesThatRequireIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root, manifest: "node-runtime.plugin.json", languageID: "fixture")
        // Use the actual writer with an invalid filesystem root, rather than a
        // fabricated planner result, to exercise the optional-storage boundary.
        let blocked = root.appendingPathComponent("blocked-logs")
        try Data("ordinary file".utf8).write(to: blocked)
        let writer = MacLogStore(defaultDirectory: blocked)
        let resolver = MacPluginLanguageServerLaunchResolver(planner: DeclarativePluginTestSupport.operations,
            directories: fixture.directories, settings: InMemoryPluginSettings(),
            logDirectory: { try writer.pluginFilesDirectory(pluginID: $0) })
        let resolved = try resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)
        #expect(resolved.arguments.contains("--stdio"))
        _ = try resolver.executableProbe(for: fixture.source)

        var manifest = try #require(JSONSerialization.jsonObject(with: fixture.source.manifest) as? [String: Any])
        var servers = try #require(manifest["languageServers"] as? [[String: Any]])
        servers[0]["arguments"] = ["--log=${logDir}/server.log"]
        manifest["languageServers"] = servers
        let source = DeclarativeLanguageServerLaunchSource(pluginID: fixture.source.pluginID, languageID: "fixture",
            manifest: try JSONSerialization.data(withJSONObject: manifest), packageURL: fixture.source.packageURL)
        #expect(throws: (any Error).self) { try resolver.resolve(source, workspaceRootURL: fixture.workspaceURL) }
        #expect(try String(contentsOf: blocked, encoding: .utf8) == "ordinary file")
        try writer.redirect(to: root.appendingPathComponent("recovered-logs"))
        let collection = try await writer.collect(query: .init(session: "all"))
        #expect(collection.writeFailures > 0)
        await writer.finishSession()
    }

    @Test
    func logDirectoryTemplateUsesTheCurrentSessionOutsideTheInstalledPackage() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root, manifest: "node-runtime.plugin.json", languageID: "fixture")
        var manifest = try #require(JSONSerialization.jsonObject(with: fixture.source.manifest) as? [String: Any])
        var servers = try #require(manifest["languageServers"] as? [[String: Any]])
        servers[0]["arguments"] = ["--stdio", "--log=${logDir}/server.log"]
        manifest["languageServers"] = servers
        let source = DeclarativeLanguageServerLaunchSource(pluginID: fixture.source.pluginID, languageID: "fixture",
            manifest: try JSONSerialization.data(withJSONObject: manifest), packageURL: fixture.source.packageURL)
        let before = try packageFiles(source.packageURL)
        let writer = MacLogStore(defaultDirectory: root.appendingPathComponent("logs"))
        let resolver = MacPluginLanguageServerLaunchResolver(planner: DeclarativePluginTestSupport.operations,
            directories: fixture.directories, settings: InMemoryPluginSettings(),
            logDirectory: { try writer.pluginFilesDirectory(pluginID: $0) })
        let resolved = try resolver.resolve(source, workspaceRootURL: fixture.workspaceURL)
        let files = try writer.pluginFilesDirectory(pluginID: source.pluginID)
        #expect(resolved.arguments.last == "--log=" + files.path + "/server.log")
        #expect(isDirectory(files))
        #expect(files.path.hasPrefix(root.resolvingSymlinksInPath().appendingPathComponent("logs/sessions").path + "/"))
        #expect(try packageFiles(source.packageURL) == before)
        #expect(throws: (any Error).self) { try fixture.resolver.resolve(source, workspaceRootURL: fixture.workspaceURL) }
        await writer.finishSession()
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
            languageID: "fixture",
            workspaceRootURL: URL(fileURLWithPath: "/projects/one")
        )
        let second = directories.workspaceStateDirectory(
            pluginID: "dev.example.plugin",
            languageID: "fixture",
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
            at: fixture.source.packageURL.appendingPathComponent("language-server/lib/server.js")
        )

        #expect(throws: MacPluginLanguageServerLaunchResolver.ResolutionError.missingPackagePath(
            "language-server/lib/server.js"
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
        let entry = fixture.source.packageURL.appendingPathComponent("language-server/lib/server.js")
        let outside = root.appendingPathComponent("outside.js")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: entry)
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: outside)

        #expect(throws: MacPluginLanguageServerLaunchResolver.ResolutionError.packagePathOutsidePackage(
            "language-server/lib/server.js"
        )) {
            try fixture.resolver.resolve(fixture.source, workspaceRootURL: fixture.workspaceURL)
        }
    }

    /// A runtime the plugin does not ship is discovered on the machine, so the
    /// probe carries its version requirement and no location inside the package.
    @Test
    func aDiscoveredRuntimeIsProbedForItsVersionWithoutAPackagedLocation() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)

        let probe = try fixture.resolver.executableProbe(for: fixture.source)

        #expect(probe.validationArguments.isEmpty)
        #expect(probe.versionRequirement?.tool == "node")
        #expect(probe.versionRequirement?.minimumVersion == "18.17")
        #expect(probe.packagedRuntimeURL == nil)
        // Expanding the probe needs no workspace and must not create state.
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.rootURL.path))
    }

    /// A runtime older than the plugin requires must not be offered, even when
    /// it is first on PATH; the first runtime that qualifies is used.
    @MainActor
    @Test
    func runtimeCandidatesBelowTheMinimumVersionAreNotUsed() async {
        let old = URL(fileURLWithPath: "/runtimes/16/bin/node")
        let stub = URL(fileURLWithPath: "/usr/bin/node")
        let current = URL(fileURLWithPath: "/runtimes/20/bin/node")
        let runner = VersionProbeRunner(outputs: [
            old.path: (0, "v16.20.2"),
            stub.path: (1, "node: command not found"),
            current.path: (0, "v20.11.0")
        ])
        let service = LanguageServerToolService(
            runtimeService: FixedLanguageToolRuntime(candidates: ["node": [old, stub, current]]),
            commandRunner: runner,
            settingsStore: MemoryLanguageToolSettings(),
            versionChecker: DeclarativePluginTestSupport.operations
        )
        let descriptor = discoveredRuntimeDescriptor()

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
        let old = URL(fileURLWithPath: "/runtimes/16/bin/node")
        let service = LanguageServerToolService(
            runtimeService: FixedLanguageToolRuntime(candidates: [:]),
            commandRunner: VersionProbeRunner(outputs: [old.path: (0, "v16.20.2")]),
            settingsStore: MemoryLanguageToolSettings(),
            versionChecker: DeclarativePluginTestSupport.operations
        )

        await #expect(throws: LanguageServerToolConfigurationError.executableValidationFailed(
            path: old.path,
            message: "node 16.20.2 is older than the required 18.17."
        )) {
            try await service.setCustomExecutablePath(old.path, for: discoveredRuntimeDescriptor())
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
        var issues: [(Bool, String, String)] = []
        session.onLogIssue = { warning, stage, code, _, _ in issues.append((warning, stage, code)) }
        session.onStateChange = { states.append($0) }

        #expect(throws: LanguageServerSessionStartError.self) {
            try session.start(rootURL: URL(fileURLWithPath: "/projects/one"))
        }
        #expect(!session.isRunning)
        guard case .failed(let failure)? = states.last else {
            Issue.record("The session did not report a failure: \(states)")
            return
        }
        #expect(failure.code == "plugin.launch.invalidRequest")
        #expect(issues.count == 1)
        #expect(issues.first?.0 == false)
        #expect(issues.first?.1 == "processStart")
        #expect(issues.first?.2 == "plugin.launch.invalidRequest")
    }

    // MARK: Declarative start attempt

    /// A launch plan Core rejects fails the plugin's start before any process
    /// exists, so the host records it at `resolve`; stopping afterwards adds nothing.
    @MainActor
    @Test
    func aFailedLaunchPlanRecordsTheDeclarativeStartAtResolve() {
        let operations = RecordedPluginOperations()
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
        session.observePluginStartup(operations.reporter.begin(
            pluginID: "dev.example.plugin", operation: .languageServerStart, at: .resolve, operationID: "lsp-start"
        ))

        #expect(throws: LanguageServerSessionStartError.self) {
            try session.start(rootURL: URL(fileURLWithPath: "/projects/one"))
        }
        session.stop()

        #expect(operations.observations == [RecordedPluginOperations.languageServerStart(
            pluginID: "dev.example.plugin", failure: .resolve, operationID: "lsp-start"
        )])
    }

    /// Stopping cancels the attempt on every stop path, so a later start of the
    /// same session cannot report the stopped one.
    @MainActor
    @Test
    func aStartStoppedBeforeLaunchIsNotReportedByALaterStart() async {
        let operations = RecordedPluginOperations()
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
        session.observePluginStartup(operations.reporter.begin(
            pluginID: "dev.example.plugin", operation: .languageServerStart, at: .resolve, operationID: "lsp-start"
        ))

        #expect(await session.stopAndWait())
        #expect(throws: LanguageServerSessionStartError.self) {
            try session.start(rootURL: URL(fileURLWithPath: "/projects/one"))
        }

        #expect(operations.observations.isEmpty)
    }

    /// The manager begins an attempt only for a server a plugin declares,
    /// whether its launch is templated (plugin API 2 and later) or literal
    /// (plugin API 1): a server the host owns has no plugin to attribute it to.
    /// The attempt carries the manager's operation ID, so it joins the
    /// session's other records.
    @MainActor
    @Test(arguments: ["launchTemplates", "pluginAPI1", "hostOwned"])
    func aServerWithoutAnExecutableRecordsOnlyADeclarativeStart(owner: String) {
        let source = DeclarativeLanguageServerLaunchSource(
            pluginID: "dev.example.plugin",
            languageID: "fixture",
            manifest: Data(),
            packageURL: URL(fileURLWithPath: "/plugins/fixture")
        )
        let declarative = owner != "hostOwned"
        let launch = LanguageServerLaunchDescriptor(
            executableNames: ["fixture-language-server"],
            arguments: [],
            launchSource: owner == "launchTemplates" ? source : nil,
            pluginID: owner == "pluginAPI1" ? "dev.example.plugin" : nil
        )
        let descriptor = LanguageProviderDescriptor(
            id: "fixture",
            displayName: "Fixture",
            fileExtensions: ["fixture"],
            capabilities: .languageServer,
            activationPolicy: .onDemand,
            languageServerLaunch: launch
        )
        let runtime = StdioLanguageProviderRuntime(
            descriptor: descriptor,
            runtimeService: FixedLanguageToolRuntime(candidates: [:]),
            languageServerLaunch: launch,
            languageServerCore: RustCoreBridge(),
            languageServerExecutableResolver: { _ in nil }
        )
        let operations = RecordedPluginOperations()
        let manager = LanguageToolingSessionManager(
            catalog: .init(descriptors: [descriptor]),
            pluginOperations: operations.reporter,
            runtimes: [runtime]
        )
        defer { manager.stopAllLanguageServers() }
        let operationID = UUID()

        // Only what is recorded matters here: with no executable every server
        // stops at discovery, and only a plugin's server has an attempt to end.
        #expect(throws: (any Error).self) {
            _ = try manager.startLanguageServer(
                providerID: descriptor.id, rootURL: URL(fileURLWithPath: "/projects/one"), operationID: operationID
            )
        }

        let expected = declarative
            ? [RecordedPluginOperations.languageServerStart(
                pluginID: "dev.example.plugin", failure: .resolve, operationID: operationID.uuidString
            )]
            : []
        #expect(operations.observations == expected)
    }

    // MARK: Fixtures

    private struct Fixture {
        let source: DeclarativeLanguageServerLaunchSource
        let directories: MacPluginStateDirectories
        let resolver: MacPluginLanguageServerLaunchResolver
        let workspaceURL: URL
    }

    /// Files the fixture manifest points at. A trailing `/` marks a directory.
    private func declaredFiles() -> [String] {
        let architecture = MacPluginLanguageServerLaunchResolver.hostArchitecture
        return [
            "language-server/lib/server.js",
            "language-server/lib/preload.js",
            "language-server/stubs/\(architecture)/"
        ]
    }

    private func makeFixture(
        root: URL,
        manifest: String = "node-runtime.plugin.json",
        languageID: String = "fixture",
        settings: any PluginSettingsStoring = InMemoryPluginSettings()
    ) throws -> Fixture {
        let operations = DeclarativePluginTestSupport.operations
        let descriptor = try operations.validate(manifest: fixtureManifest(manifest))
        let packageURL = root.appendingPathComponent("package", isDirectory: true)
        for relativePath in declaredFiles() {
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

    private func discoveredRuntimeDescriptor() -> LanguageProviderDescriptor {
        LanguageProviderDescriptor(
            id: "fixture",
            displayName: "Fixture",
            fileExtensions: ["fixture"],
            capabilities: .languageServer,
            activationPolicy: .onDemand,
            languageServerLaunch: LanguageServerLaunchDescriptor(
                executableNames: ["node"],
                executableVersionRequirement: LanguageServerExecutableVersionRequirement(
                    tool: "node",
                    minimumVersion: "18.17",
                    probeArguments: ["--version"]
                )
            )
        )
    }

    private func fixtureManifest(_ name: String) throws -> Data {
        try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/languages")
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
