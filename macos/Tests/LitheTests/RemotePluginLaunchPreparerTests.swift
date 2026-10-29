import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Remote plugin launch preparation")
@MainActor
struct RemotePluginLaunchPreparerTests {
    @Test
    func realDeclarationExpandsWithTargetArchitectureAndRemoteWritableState() async throws {
        let fixture = try LaunchFixture()
        let tools = LaunchTools()
        let result = try await fixture.preparer.prepareLanguage(fixture.descriptor,
            workspaceURL: fixture.workspace, tools: tools, versionChecker: DeclarativePluginTestSupport.operations)
        #expect(result.executableURL.path == "/host/bin/node")
        #expect(tools.invocation?.executables == [.runtime("node")])
        #expect(tools.invocation?.runtimeDependencies.first?.minimumVersion == "18.17")
        #expect(result.launch.arguments.contains("--max-old-space-size=4096"))
        #expect(result.launch.arguments.contains("/host/package/language-server/lib/server.js"))
        #expect(result.launch.initializationOptions == .object([
            "stubs": .array([.string("/host/package/language-server/stubs/arm64")]), "telemetry": .bool(false)
        ]))
        #expect(result.environment["OPAQUE"] == fixture.workspace.path)
        #expect(fixture.host.created.count == 2)
        #expect(fixture.host.created.allSatisfy { $0.hasPrefix("/host/.lithe-server/state/plugins/") })
        #expect(fixture.host.checked.allSatisfy { $0.hasPrefix("/host/package/") })
        #expect(fixture.host.released.isEmpty)
        fixture.rebind()
        await result.release()
        #expect(fixture.host.released == ["original"])
    }

    @Test
    func missingTargetResourceFailsAndReleasesTheDeployedSnapshot() async throws {
        let fixture = try LaunchFixture()
        fixture.host.missingResource = true
        let tools = LaunchTools()
        await #expect(throws: CocoaError.self) {
            _ = try await fixture.preparer.prepareLanguage(fixture.descriptor,
                workspaceURL: fixture.workspace, tools: tools, versionChecker: DeclarativePluginTestSupport.operations)
        }
        #expect(tools.invocation == nil)
        #expect(fixture.host.created.isEmpty)
        #expect(fixture.host.released == ["original"])
    }

    @Test
    func reconnectDuringPreparationRejectsStaleLaunchAndReleasesOriginalHost() async throws {
        let fixture = try LaunchFixture()
        let tools = LaunchTools()
        tools.onResolve = { fixture.rebind() }
        await #expect(throws: CancellationError.self) {
            _ = try await fixture.preparer.prepareLanguage(fixture.descriptor,
                workspaceURL: fixture.workspace, tools: tools, versionChecker: DeclarativePluginTestSupport.operations)
        }
        #expect(fixture.host.released == ["original"])
    }

    @Test
    func cancelledToolPreparationReleasesOriginalSnapshot() async throws {
        let fixture = try LaunchFixture()
        let tools = LaunchTools()
        tools.blocked = true
        let completed = TestGate()
        let task = Task {
            defer { completed.open() }
            return try await fixture.preparer.prepareLanguage(fixture.descriptor,
                workspaceURL: fixture.workspace, tools: tools, versionChecker: DeclarativePluginTestSupport.operations)
        }
        defer { task.cancel(); tools.release.open() }
        try #require(await tools.started.waitUntilOpen(timeout: .seconds(5)))
        task.cancel()
        tools.release.open()
        try #require(await completed.waitUntilOpen(timeout: .seconds(5)))
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(fixture.host.released == ["original"])
    }
}

@MainActor
private struct LaunchFixture {
    let workspace = URL(fileURLWithPath: "/fixture/remote-placeholder")
    let registry = RemoteWorkspaceRegistry()
    let host: LaunchHost
    let preparer: MacRemotePluginLaunchPreparer
    let descriptor: LanguageServerLaunchDescriptor

    init() throws {
        let data = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/node-runtime.plugin.json"))
        let validated = try DeclarativePluginTestSupport.operations.validate(manifest: data)
        let settings = InMemoryPluginSettings()
        settings.setValue(.integer(4096), forSetting: "heapMB", plugin: validated.id.rawValue)
        host = LaunchHost(manifest: validated.normalizedManifest)
        let package = URL(fileURLWithPath: "/local/approved-package")
        descriptor = .init(executableNames: ["node"], environment: ["OPAQUE": workspace.path],
            launchSource: .init(pluginID: validated.id.rawValue, languageID: "fixture",
                manifest: validated.normalizedManifest, packageURL: package))
        registry.register(.init(root: workspace, remoteRoot: "/host/project", sessionID: "original", connectionID: UUID()))
        let operations = DeclarativePluginTestSupport.operations
        preparer = .init(registry: registry, packages: host, host: host, planner: operations,
            resolver: .init(planner: operations,
                directories: .init(rootURL: URL(fileURLWithPath: "/unused/local-state")), settings: settings), core: RustCoreBridge())
    }

    func rebind() {
        registry.register(.init(root: workspace, remoteRoot: "/replacement/project", sessionID: "replacement", connectionID: UUID()))
    }
}

private final class LaunchHost: RemotePluginFileAccess, RemotePluginPackageDeploying, @unchecked Sendable {
    let manifest: Data
    private let lock = NSLock()
    private var releases: [String] = []
    var released: [String] { lock.withLock { releases } }
    // Requests are awaited sequentially; tests inspect state after completion.
    var missingResource = false
    var checked: [String] = []
    var created: [String] = []
    init(manifest: Data) { self.manifest = manifest }
    func buildRequiresPackage(pluginID: String, buildSystemID: String, packageURL: URL) throws -> Bool { true }
    func deploy(pluginID: String, packageURL: URL, session: String) async throws -> RemoteDeployedPluginPackage {
        .init(packageURL: URL(fileURLWithPath: "/host/package"), manifest: manifest, architecture: "arm64",
            release: { self.lock.withLock { self.releases.append(session) } })
    }
    func pluginHost(session: String) async throws -> RemotePluginHost {
        #expect(session == "original")
        return .init(os: "linux", arch: "aarch64", homeDirectory: "/host", features: ["upload"])
    }
    func pluginRequest(_ method: String, params: ToolingJSONValue, session: String) async throws -> ToolingJSONValue {
        #expect(session == "original")
        guard case .object(let values) = params, case .string(let path) = values["path"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if method == "fs.stat" {
            checked.append(path)
            return .object(["kind": .string(missingResource ? "missing" : "file")])
        }
        #expect(method == "fs.createDir")
        created.append(path)
        return .null
    }
    func uploadPluginFile(_ source: URL, to path: String, sha256: String, mode: UInt32, session: String) async throws {
        Issue.record("Launch planning must use the deployment port, never upload independently")
    }
}

@MainActor
private final class LaunchTools: BuildToolResolving {
    var invocation: BuildInvocation?
    var onResolve: (() -> Void)?
    var blocked = false
    let started = TestGate()
    let release = TestGate()
    func resolve(_ invocation: BuildInvocation, displayName: String, workspaceURL: URL,
                 checkVersion: @escaping @Sendable (String?, String) throws -> BuildVersionCheck) async throws -> ResolvedBuildTool {
        self.invocation = invocation
        #expect(try checkVersion(nil, "v20.3.0").satisfied)
        onResolve?()
        if blocked {
            started.open()
            _ = await release.waitUntilOpen(timeout: .seconds(5))
            try Task.checkCancellation()
        }
        return .init(executableURL: URL(fileURLWithPath: "/host/bin/node"), environment: [:], executesProjectCode: false, version: "20.3.0")
    }
}
