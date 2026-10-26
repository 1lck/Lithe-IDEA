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
    func transportOnlyLaunchesExecutablesFromThePluginPackage() {
        let transport = MacPluginDebugAdapterTransport(
            adapterID: "lldb",
            resolve: { _ in Self.process(.commands(["lldb-dap"])) },
            makeProcess: { Issue.record("No process starts for a non-packaged executable."); fatalError() }
        )
        #expect(throws: MacPluginDebugAdapterTransport.TransportError.self) {
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
