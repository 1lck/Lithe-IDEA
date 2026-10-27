import Foundation
import LitheCoreContracts
import LitheModuleAPI
import LitheDebugModule
import Testing
@testable import Lithe

@Suite("Plugin debug adapter host")
@MainActor
struct PluginDebugAdapterTests {
    private struct ResolveFailure: Error, Equatable {}

    @Test(arguments: ["valid", "not-executable", "withdrawn", "replaced", "program-alias", "instance-alias"])
    func providerDebugHandoffRechecksFilesAndCurrentPackage(change: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-debug-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let instance = workspace.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
        let program = instance.appendingPathComponent("main")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let fixture = DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent("shared/contracts/plugins/v1/fixtures/build-provider-debug-preparation.plugin.json")
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: Data(contentsOf: fixture))
        let package = InstalledPluginPackage(descriptor: descriptor, installation: PluginInstallationRecord(
            pluginID: descriptor.id, activeVersion: descriptor.pluginManifest.version, origin: .marketplace, status: .installed),
            packageURL: root.appendingPathComponent("package", isDirectory: true))
        let entry = try #require(PluginDebugAdapterEntry.qualifiedIndex(of: [package]).values.first)
        let source = BuildSystemPluginSource(pluginID: descriptor.id.rawValue, manifest: descriptor.normalizedManifest, packageURL: package.packageURL, buildSystems: descriptor.buildSystems)
        let plan = try JSONDecoder().decode(BuildDebugPreparation.self, from: Data(
            #"{"root":"app","adapter":"native","program":"app/main","arguments":["a b","x#y"],"workingDirectory":"app","environment":{"MODE":"debug"}}"#.utf8))
        let lookup = entry.provider(languages: [])
        #expect(lookup.matches(URL(fileURLWithPath: "/workspace/main.c")))
        #expect(!lookup.selectsByFile)
        var current: PluginDebugAdapterEntry? = entry
        switch change {
        case "not-executable": try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: program.path)
        case "withdrawn": current = nil
        case "replaced":
            let other = InstalledPluginPackage(descriptor: descriptor, installation: package.installation,
                packageURL: root.appendingPathComponent("replacement", isDirectory: true))
            current = PluginDebugAdapterEntry(plugin: other, adapter: entry.adapter)
        case "program-alias", "instance-alias":
            let other = workspace.appendingPathComponent("other", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let outside = other.appendingPathComponent("main")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: outside)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outside.path)
            if change == "program-alias" {
                try FileManager.default.removeItem(at: program)
                try FileManager.default.createSymbolicLink(at: program, withDestinationURL: outside)
            } else {
                let external = root.appendingPathComponent("external", isDirectory: true)
                try FileManager.default.moveItem(at: instance, to: external)
                try FileManager.default.createSymbolicLink(at: instance, withDestinationURL: external)
            }
        default: break
        }
        let resolver = MacBuildDebugLaunchResolver(planner: DeclarativePluginTestSupport.operations,
            entry: { _ in current }, generation: { 7 })
        if change == "valid" {
            let launch = try resolver.resolve(source: source, preparation: plan, workspaceURL: workspace, title: "Main")
            #expect(launch.adapterProviderID == entry.providerID)
            #expect(launch.arguments["args"] == .array([.string("a b"), .string("x#y")]))
            #expect(launch.arguments["env"] == .object(["MODE": .string("debug")]))
            #expect(launch.arguments["program"] == .string(program.resolvingSymlinksInPath().path))
        } else {
            #expect(throws: DebugLaunchConfigurationResolutionError.providerDebugUnavailable) {
                try resolver.resolve(source: source, preparation: plan, workspaceURL: workspace, title: "Main")
            }
        }
    }


    @Test
    func explicitHostIdentityCrossesTheRealCoreBridgeWithoutBecomingADAPArgument() throws {
        let core = RustCoreBridge()
        let id = "explicit-adapter-\(UUID().uuidString)"
        _ = try core.createDebugSession(sessionID: id, adapterID: "example-dap", rootPath: "/workspace/example",
            supportsRunInTerminalRequest: false, supportsStartDebuggingRequest: false,
            disabledCapabilities: [], parentSessionID: nil)
        defer { core.destroyDebugSession(sessionID: id) }
        let body = Data(#"{"seq":1,"type":"response","request_seq":1,"command":"initialize","success":true,"body":{}}"#.utf8)
        var reply = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        reply.append(body)
        _ = try core.receiveDebugData(sessionID: id, data: reply)
        let launch = try core.launchDebugSession(sessionID: id, operationID: "launch", configuration:
            DebugLaunchConfiguration(name: "example", request: .launch,
                arguments: ["program": .string("bin/example")], adapterProviderID: "dev.example.native/lldb"))
        let frame = try #require(launch.outboundFrames.first)
        let bytes = try #require(Data(base64Encoded: frame))
        let separator = try #require(bytes.range(of: Data("\r\n\r\n".utf8)))
        let message = try #require(JSONSerialization.jsonObject(with: bytes[separator.upperBound...]) as? [String: Any])
        let arguments = try #require(message["arguments"] as? [String: Any])
        #expect(message["command"] as? String == "launch")
        #expect(arguments["program"] as? String == "bin/example")
        #expect(arguments["adapterProviderID"] == nil)
        #expect(message["adapterProviderID"] == nil)
    }

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
