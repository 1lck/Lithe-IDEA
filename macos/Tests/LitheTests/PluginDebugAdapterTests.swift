import Foundation
import LitheCoreContracts
import LitheDebugModule
import Testing
@testable import Lithe

@Suite("Plugin debug adapter host")
@MainActor
struct PluginDebugAdapterTests {
    private struct ResolveFailure: Error, Equatable {}

    private static func process(_ executable: MacPluginLanguageServerLaunchResolver.BuildProviderProcess.Executable)
        -> MacPluginLanguageServerLaunchResolver.DebugAdapterProcess
    {
        .init(
            process: .init(
                executable: executable, arguments: [], initializationOptions: nil, runtimeTools: [],
                executesProjectCode: true, mayUseNetwork: false, settings: [:]
            ),
            adapter: .init(
                id: "lldb", providerID: "acme/lldb", displayName: "LLDB", adapterID: "lldb-dap",
                requests: ["launch"], languageIDs: ["rust"]
            )
        )
    }

    @Test
    func aMissingSystemCommandFailsTheStartWithInstallGuidance() {
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "lldb",
            resolve: { _ in Self.process(.commands(["lldb-dap"])) },
            makeProcess: { Issue.record("No process starts for a missing command."); fatalError() },
            findCommand: { _ in nil }
        )
        #expect(throws: MacPluginDebugAdapterTransport.TransportError.commandNotFound(adapterID: "lldb", commands: ["lldb-dap"])) {
            try transport.start(rootURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true))
        }
        #expect(!transport.isRunning)
    }

    @Test
    func aRejectedLaunchPlanSurfacesAsTheStartError() {
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "lldb",
            resolve: { _ in throw ResolveFailure() },
            makeProcess: { Issue.record("No process starts when the plan is rejected."); fatalError() }
        )
        #expect(throws: ResolveFailure()) {
            try transport.start(rootURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true))
        }
    }

    // MARK: - Launch transport

    /// Resolves the fixture's `native` adapter, declared over `transport`.
    private func resolveNativeAdapter(
        transport: String,
        endpoint: [String: Any]? = nil
    ) throws -> MacPluginLanguageServerLaunchResolver.DebugAdapterProcess {
        let url = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/debug-adapter.plugin.json")
        var manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var adapters = try #require(manifest["debugAdapters"] as? [[String: Any]])
        let index = try #require(adapters.firstIndex { $0["id"] as? String == "native" })
        var launch = try #require(adapters[index]["launch"] as? [String: Any])
        launch["transport"] = transport
        launch["endpoint"] = endpoint
        adapters[index]["launch"] = launch
        manifest["debugAdapters"] = adapters

        let operations = DeclarativePluginTestSupport.operations
        let descriptor = try operations.validate(manifest: JSONSerialization.data(withJSONObject: manifest))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-debug-transport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = MacPluginLanguageServerLaunchResolver(
            planner: operations,
            directories: MacPluginStateDirectories(rootURL: root.appendingPathComponent("state", isDirectory: true)),
            settings: InMemoryPluginSettings()
        )
        return try resolver.resolveDebugAdapter(
            pluginID: descriptor.id.rawValue,
            adapterID: "native",
            manifest: descriptor.normalizedManifest,
            packageURL: root.appendingPathComponent("package", isDirectory: true),
            workspaceRootURL: root.appendingPathComponent("workspace", isDirectory: true)
        )
    }

    @Test
    func aStdioAdapterResolvesToItsLaunch() throws {
        let resolved = try resolveNativeAdapter(transport: "stdio")
        #expect(resolved.adapter.transport == "stdio")
    }

    /// The host only speaks stdio, so a TCP adapter would be started and never
    /// reached; it is refused before any process exists.
    @Test(arguments: ["tcpPort", "tcpAnnounced"])
    func aTCPAdapterIsRefusedBeforeItsProcessIsStarted(_ transport: String) {
        let endpoint: [String: Any] = transport == "tcpPort"
            ? ["port": 4711]
            : ["stream": "stdout", "prefix": "listening on ", "value": "port"]
        do {
            _ = try resolveNativeAdapter(transport: transport, endpoint: endpoint)
            Issue.record("A \(transport) adapter must not resolve to a process.")
        } catch let rejection as DeclarativePluginRejection {
            #expect(rejection.code == "plugin.launch.unsupportedTransport")
            #expect(rejection.field == "debugAdapters.launch.transport")
            #expect(rejection.message.contains(transport))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func unknownProvidersFallBackToThePluginLaunch() throws {
        let document = URL(fileURLWithPath: "/tmp/workspace/src/main.zig")
        let root = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        let provider = LanguageProviderDescriptor(
            id: "zig", displayName: "Zig", fileExtensions: ["zig"],
            capabilities: [.debugAdapter], activationPolicy: .onDemand
        )
        var asked: [String] = []
        let resolver = DebugLaunchConfigurationResolver(
            pluginLaunch: { languageID, _, _ in
                asked.append(languageID)
                return DebugLaunchConfiguration(name: "main.zig", request: .launch, arguments: [:])
            }
        )
        let configuration = try resolver.resolve(
            provider: provider, documentURL: document, workspaceURL: root,
            configurations: [], selectedConfiguration: nil, javaTarget: nil, options: { _ in RunOptions() }
        )
        #expect(asked == ["zig"])
        #expect(configuration.name == "main.zig")

        let without = DebugLaunchConfigurationResolver()
        #expect(throws: DebugLaunchConfigurationResolutionError.self) {
            try without.resolve(
                provider: provider, documentURL: document, workspaceURL: root,
                configurations: [], selectedConfiguration: nil, javaTarget: nil, options: { _ in RunOptions() }
            )
        }
    }
}
