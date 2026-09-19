import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheLanguageIntelligenceModule
import LitheModuleAPI
import Testing

@MainActor
struct ExtensionHostModuleTests {
    @Test(arguments: [false, true])
    func disabledAndSafeModeDoNotConstructHost(safeMode: Bool) async throws {
        let runtime = ModuleRuntime(launchMode: safeMode ? .safeMode : .normal)
        let recorder = HostModuleRecorder()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: HostLanguageModule.moduleManifest) { HostLanguageModule() })
        try runtime.register(factory(recorder), enabled: safeMode)
        let expected: ModuleRuntimeError = safeMode
            ? .optionalModuleUnavailableInSafeMode(JavaExtensionPluginCatalog.moduleID)
            : .moduleDisabled(JavaExtensionPluginCatalog.moduleID)
        await #expect(throws: expected) {
            _ = try await runtime.activateCapability(JavaExtensionPluginCatalog.capabilityID)
        }
        #expect(recorder.transports.isEmpty)
        #expect(try !runtime.snapshot(for: JavaExtensionPluginCatalog.moduleID).isInstantiated)
    }

    @Test func disableStopsHostAndReenableCreatesNewGeneration() async throws {
        let runtime = ModuleRuntime()
        let recorder = HostModuleRecorder()
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: HostLanguageModule.moduleManifest) { HostLanguageModule() })
        try runtime.register(factory(recorder), enabled: true)
        let first = try #require(try await runtime.activateCapability(JavaExtensionPluginCatalog.capabilityID) as? ExtensionHostCapability)
        _ = try await first.session.start(ExtensionHostLaunchConfiguration(
            node: URL(fileURLWithPath: "/fixture/node"), entrypoint: URL(fileURLWithPath: "/fixture/host.js"),
            workspace: URL(fileURLWithPath: "/fixture/workspace"), environment: [:]), initialize: .object([:]))
        #expect(first.session.isModuleResourceActive)
        try await runtime.setEnabled(false, for: JavaExtensionPluginCatalog.moduleID)
        #expect(first.session.state == .stopped)
        #expect(recorder.transports[0].stopCount == 1)
        #expect(!first.session.isModuleResourceActive)
        try await runtime.setEnabled(true, for: JavaExtensionPluginCatalog.moduleID)
        let second = try #require(try await runtime.activateCapability(JavaExtensionPluginCatalog.capabilityID) as? ExtensionHostCapability)
        #expect(first.session !== second.session)
        #expect(second.session.state == .idle)
        try await runtime.setEnabled(false, for: JavaExtensionPluginCatalog.moduleID)
    }

    @Test func notificationsRouteAndStopClearsOnlyTheirGeneration() async throws {
        let manager = LanguageToolingSessionManager()
        let first = ExtensionHostSession(transport: HostModuleTransport())
        let second = ExtensionHostSession(transport: HostModuleTransport())
        manager.attachExtensionHostSession(first)
        manager.attachExtensionHostSession(second)
        defer {
            manager.detachExtensionHostSession(first)
            manager.detachExtensionHostSession(second)
        }
        let url = URL(fileURLWithPath: "/fixture/A.java")
        func notify(_ session: ExtensionHostSession, method: String, params: ToolingJSONValue) throws {
            var bytes = try JSONEncoder().encode(ToolingJSONValue.object([
                "kind": .string("notification"), "method": .string(method), "params": params
            ]))
            bytes.append(10)
            session.connection.receive(bytes)
        }
        let registration: ToolingJSONValue = .object([
            "kind": .string("hover"), "handle": .integer(1),
            "selector": .array([.object(["language": .string("java")])])
        ])
        try notify(first, method: "lithe/languageProviderRegistered", params: registration)
        try notify(second, method: "lithe/languageProviderRegistered", params: registration)
        #expect(manager.features(for: url).contains(.hover))
        let delta: ToolingJSONValue = .object([
            "id": .string("probe"), "delta": .array([.array([.string(url.absoluteString), .array([
                .object(["message": .string("problem"), "severity": .integer(1),
                    "range": .object(["startLine": .integer(2), "startColumn": .integer(3),
                        "endLine": .integer(2), "endColumn": .integer(6)])])
            ])])])
        ])
        try notify(first, method: "lithe/diagnosticsChanged", params: delta)
        try notify(second, method: "lithe/diagnosticsChanged", params: delta)
        #expect(manager.diagnostics[url]?.count == 2)
        #expect(manager.diagnostics[url]?.first?.range.start.line == 1)
        #expect(manager.diagnostics[url]?.first?.range.start.utf16Column == 2)
        await first.stop()
        #expect(manager.features(for: url).contains(.hover))
        #expect(manager.diagnostics[url]?.count == 1)
        // Closed generations must not re-register providers or restore diagnostics.
        try notify(first, method: "lithe/diagnosticsChanged", params: delta)
        #expect(manager.diagnostics[url]?.count == 1)
        try notify(second, method: "lithe/diagnosticsCleared", params: .object(["id": .string("probe")]))
        #expect(manager.diagnostics[url] == nil)
        try notify(second, method: "lithe/languageProviderUnregistered", params: .object(["handle": .integer(1)]))
        #expect(!manager.features(for: url).contains(.hover))
        await second.stop()
    }

    @Test(arguments: [false, true])
    func activationStartsConfiguredHostOrCleansFailedStartup(fail: Bool) async throws {
        let runtime = ModuleRuntime()
        let transport = HostModuleTransport()
        if fail {
            transport.initializeResult = .object(["protocolVersion": .integer(1),
                "failedExtensions": .array([.object(["message": .string("Fixture extension failed")])])])
        }
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: HostLanguageModule.moduleManifest) { HostLanguageModule() })
        try runtime.register(ModuleFactory(manifest: JavaExtensionPluginCatalog.moduleManifest) {
            ExtensionHostModule(manifest: JavaExtensionPluginCatalog.moduleManifest,
                capabilityID: JavaExtensionPluginCatalog.capabilityID,
                makeSession: { ExtensionHostSession(transport: transport) },
                startup: { _ in
                    return ExtensionHostStartupConfiguration(
                        launch: ExtensionHostLaunchConfiguration(node: URL(fileURLWithPath: "/fixture/node"),
                            entrypoint: URL(fileURLWithPath: "/fixture/main.js"),
                            workspace: URL(fileURLWithPath: "/fixture/workspace"), environment: [:]),
                        initialize: .object([:]))
                })
        }, enabled: true)
        if fail {
            await #expect(throws: (any Error).self) {
                _ = try await runtime.activateCapability(JavaExtensionPluginCatalog.capabilityID)
            }
            #expect(!transport.isRunning)
            #expect(transport.stopCount > 0)
            #expect(runtime.capability(JavaExtensionPluginCatalog.capabilityID) == nil)
        } else {
            let capability = try #require(try await runtime.activateCapability(JavaExtensionPluginCatalog.capabilityID) as? ExtensionHostCapability)
            #expect(capability.session.state == .ready)
            #expect(transport.isRunning)
            try await runtime.setEnabled(false, for: JavaExtensionPluginCatalog.moduleID)
            #expect(!transport.isRunning)
        }
    }

    @Test func ownershipBlocksLegacyRestartUntilProcessCleanupSucceeds() async throws {
        let manager = LanguageToolingSessionManager()
        let transport = HostModuleTransport()
        let first = ExtensionHostSession(transport: transport)
        let second = ExtensionHostSession(transport: HostModuleTransport())
        let root = URL(fileURLWithPath: "/fixture/workspace")
        try await manager.acquireExtensionHostOwnership(providerID: "java", session: first) {
            // The reservation must already exist while native teardown is awaited.
            do {
                _ = try manager.startLanguageServer(providerID: "java", rootURL: root)
                Issue.record("Legacy provider started during teardown")
            } catch {
                #expect(error.localizedDescription.contains("owned by the extension host"))
            }
        }
        #expect(manager.hasExtensionHostOwnership)
        var attemptedSecondStop = false
        await #expect(throws: ExtensionHostFailure.self) {
            try await manager.acquireExtensionHostOwnership(providerID: "java", session: second) {
                attemptedSecondStop = true
            }
        }
        #expect(!attemptedSecondStop)
        first.connection.close()
        #expect(manager.hasExtensionHostOwnership)
        transport.stopSucceeds = false
        #expect(await first.stop() == false)
        #expect(manager.hasExtensionHostOwnership)
        transport.stopSucceeds = true
        #expect(await first.stop())
        #expect(!manager.hasExtensionHostOwnership)
        try await manager.acquireExtensionHostOwnership(providerID: "java", session: second, stopLegacy: {})
        #expect(manager.hasExtensionHostOwnership)
        await second.stop()
        #expect(!manager.hasExtensionHostOwnership)
    }

    @Test func failedLegacyTeardownReleasesUnstartedReservation() async throws {
        let manager = LanguageToolingSessionManager()
        let first = ExtensionHostSession(transport: HostModuleTransport())
        await #expect(throws: ExtensionHostFailure.self) {
            try await manager.acquireExtensionHostOwnership(providerID: "java", session: first) {
                throw ExtensionHostFailure("timeout", "Legacy cleanup failed")
            }
        }
        #expect(!manager.hasExtensionHostOwnership)
        #expect(first.state == .idle)
        let second = ExtensionHostSession(transport: HostModuleTransport())
        try await manager.acquireExtensionHostOwnership(providerID: "java", session: second, stopLegacy: {})
        await second.stop()
        await first.stop()
        #expect(!manager.hasExtensionHostOwnership)
    }

    @Test func missingResourcesDoNotBeginProviderTakeover() async throws {
        let runtime = ModuleRuntime()
        let recorder = HostModuleRecorder()
        var takeoverAttempted = false
        try runtime.register(workspaceFactory())
        try runtime.register(ModuleFactory(manifest: HostLanguageModule.moduleManifest) { HostLanguageModule() })
        try runtime.register(ModuleFactory(manifest: JavaExtensionPluginCatalog.moduleManifest) {
            ExtensionHostModule(manifest: JavaExtensionPluginCatalog.moduleManifest,
                capabilityID: JavaExtensionPluginCatalog.capabilityID,
                makeSession: {
                    let transport = HostModuleTransport()
                    recorder.transports.append(transport)
                    return ExtensionHostSession(transport: transport)
                },
                startup: { _ in throw ExtensionHostFailure("notInitialized", "Missing resources") },
                onSessionCreated: { _, _ in takeoverAttempted = true })
        }, enabled: true)
        await #expect(throws: (any Error).self) {
            _ = try await runtime.activateCapability(JavaExtensionPluginCatalog.capabilityID)
        }
        #expect(!takeoverAttempted)
        #expect(recorder.transports.isEmpty)
    }

    @Test func workspaceCloseDuringTakeoverCannotStartNewHost() async throws {
        let manager = LanguageToolingSessionManager()
        let session = ExtensionHostSession(transport: HostModuleTransport())
        await #expect(throws: ExtensionHostFailure.self) {
            try await manager.acquireExtensionHostOwnership(providerID: "java", session: session) {
                session.requestStop()
            }
        }
        #expect(!manager.hasExtensionHostOwnership)
        await session.stop()
        #expect(session.state == .stopped)
    }

    @Test(arguments: [false, true])
    func hostDisconnectTriggersOwnedProcessGroupCleanup(processExited: Bool) async throws {
        let manager = LanguageToolingSessionManager()
        let transport = HostModuleTransport()
        let session = ExtensionHostSession(transport: transport)
        try await manager.acquireExtensionHostOwnership(providerID: "java", session: session, stopLegacy: {})
        _ = try await session.start(ExtensionHostLaunchConfiguration(
            node: URL(fileURLWithPath: "/fixture/node"), entrypoint: URL(fileURLWithPath: "/fixture/main.js"),
            workspace: URL(fileURLWithPath: "/fixture/workspace"), environment: [:]), initialize: .object([:]))
        if processExited {
            transport.onExit?(7)
        } else {
            // Protocol EOF does not mean Node or its JDT child has exited.
            transport.onOutput?(Data())
            #expect(transport.isRunning)
        }
        #expect(session.state == .stopping)
        #expect(manager.hasExtensionHostOwnership)
        #expect(await session.stop())
        #expect(transport.stopCount == 1)
        #expect(!manager.hasExtensionHostOwnership)
    }

    @Test func languageDisableStopsExtensionOwnerAndWaitsForCleanup() async throws {
        let manager = LanguageToolingSessionManager()
        let transport = HostModuleTransport()
        let session = ExtensionHostSession(transport: transport)
        try await manager.acquireExtensionHostOwnership(providerID: "java", session: session, stopLegacy: {})
        _ = try await session.start(ExtensionHostLaunchConfiguration(
            node: URL(fileURLWithPath: "/fixture/node"), entrypoint: URL(fileURLWithPath: "/fixture/main.js"),
            workspace: URL(fileURLWithPath: "/fixture/workspace"), environment: [:]), initialize: .object([:]))
        manager.stopLanguageServer(providerID: "java")
        #expect(session.state == .stopping)
        #expect(manager.hasExtensionHostOwnership)
        await manager.waitForExtensionHostCleanup()
        #expect(session.state == .stopped)
        #expect(!manager.hasExtensionHostOwnership)
        #expect(transport.stopCount == 1)
    }

    private func factory(_ recorder: HostModuleRecorder) -> ModuleFactory {
        ModuleFactory(manifest: JavaExtensionPluginCatalog.moduleManifest) {
            ExtensionHostModule(manifest: JavaExtensionPluginCatalog.moduleManifest,
                capabilityID: JavaExtensionPluginCatalog.capabilityID, makeSession: {
                    let transport = HostModuleTransport()
                    recorder.transports.append(transport)
                    return ExtensionHostSession(transport: transport)
                })
        }
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: HostWorkspaceModule.moduleManifest) { HostWorkspaceModule() }
    }
}

@MainActor
private final class HostModuleRecorder { var transports: [HostModuleTransport] = [] }

@MainActor
private final class HostWorkspaceModule: LitheModule {
    static let moduleManifest = ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace, isRequired: true)
    let manifest = moduleManifest
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}

@MainActor
final class HostModuleTransport: ExtensionHostProcessTransport {
    var onOutput: ((Data) -> Void)?
    var onDiagnostic: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    var isRunning = false
    var stopCount = 0
    var stopSucceeds = true
    var initializeResult: ToolingJSONValue = .object(["protocolVersion": .integer(1)])
    func start(_ configuration: ExtensionHostLaunchConfiguration) throws { isRunning = true }
    func stop() async -> Bool { stopCount += 1; if stopSucceeds { isRunning = false }; return stopSucceeds }
    func send(_ data: Data) async throws {
        let message = try JSONDecoder().decode([String: ToolingJSONValue].self, from: data)
        guard message["kind"] == .string("request"), let id = message["id"] else { return }
        let result: ToolingJSONValue = message["method"] == .string("host/initialize")
            ? initializeResult : .null
        var response = try JSONEncoder().encode(ToolingJSONValue.object(["kind": .string("response"), "id": id, "result": result]))
        response.append(10)
        onOutput?(response)
    }
}

@MainActor
private final class HostLanguageModule: LitheModule {
    static let moduleManifest = ModuleManifest(id: .languageIntelligence, displayName: "Language", scope: .workspace)
    let manifest = moduleManifest
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
