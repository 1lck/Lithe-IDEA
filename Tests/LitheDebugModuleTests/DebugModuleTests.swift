import Foundation
import LitheApplicationKernel
import LitheCoreContracts
@testable import LitheDebugModule
import LitheModuleAPI
import Testing

@MainActor
struct DebugModuleTests {
    @Test
    func protocolSessionInitializesAndStopsThroughInjectedTransport() throws {
        let transport = RecordingTransport()
        let session = DebugAdapterProtocolSession(
            adapterID: "test-adapter",
            transport: transport
        )

        try session.start(rootURL: URL(fileURLWithPath: "/tmp/debug-module"))

        #expect(session.state == .initializing)
        #expect(transport.isRunning)
        let initialize = try #require(transport.request(named: "initialize"))
        transport.emitJSON([
            "seq": 2,
            "type": "response",
            "request_seq": initialize["seq"] as! Int,
            "success": true,
            "command": "initialize",
            "body": ["supportsConfigurationDoneRequest": true]
        ])
        #expect(session.state == .ready)

        session.stop()

        #expect(!transport.isRunning)
        #expect(session.state == .idle)
        #expect(transport.stopCalls == 1)
    }

    @Test
    func protocolSessionCreatesAndStopsChildTransport() throws {
        let parent = RecordingTransport()
        let session = DebugAdapterProtocolSession(adapterID: "test-adapter", transport: parent)
        let root = URL(fileURLWithPath: "/tmp/debug-child", isDirectory: true)

        try session.start(rootURL: root)
        let initialize = try #require(parent.request(named: "initialize"))
        parent.emitJSON([
            "seq": 2,
            "type": "response",
            "request_seq": initialize["seq"] as! Int,
            "success": true,
            "command": "initialize",
            "body": [:]
        ])
        parent.emitJSON([
            "seq": 3,
            "type": "request",
            "command": "startDebugging",
            "arguments": [
                "configuration": [
                    "name": "Child",
                    "request": "launch",
                    "program": root.appendingPathComponent("main.js").path
                ]
            ]
        ])

        let child = try #require(parent.children.first)
        #expect(child.isRunning)
        #expect(child.request(named: "initialize") != nil)
        #expect(parent.response(to: 3)?["success"] as? Bool == true)

        session.stop()

        #expect(!child.isRunning)
        #expect(child.stopCalls == 1)
    }

    @Test
    func disabledDebugDoesNotConstructGraph() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(languageFactory())
        try runtime.register(executionFactory())
        try runtime.register(ModuleFactory(manifest: DebugModule.moduleManifest, contributions: DebugModule.moduleContributions) {
            recorder.factoryCalls += 1
            return DebugModule(makeGraph: {
                recorder.graphCalls += 1
                return TestGraph()
            })
        }, enabled: false)

        await #expect(throws: ModuleRuntimeError.moduleDisabled(.debug)) {
            _ = try await runtime.activateCapability(.debugWorkspace)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.graphCalls == 0)
    }

    @Test
    func sleepReleasesDebugGraphAndWakeCreatesNewOne() async throws {
        let recorder = Recorder()
        let runtime = ModuleRuntime()
        try runtime.register(workspaceFactory())
        try runtime.register(languageFactory())
        try runtime.register(executionFactory())
        try runtime.register(ModuleFactory(manifest: DebugModule.moduleManifest, contributions: DebugModule.moduleContributions) {
            recorder.factoryCalls += 1
            return DebugModule(makeGraph: {
                recorder.graphCalls += 1
                let graph = TestGraph()
                recorder.latestGraph = graph
                return graph
            })
        })

        let first = try #require(
            try await runtime.activateCapability(.debugWorkspace) as? DebugModuleCapability
        )
        let firstJavaID = ObjectIdentifier(first.javaFeature)
        weak var released = recorder.latestGraph
        try await runtime.sleep(.debug)

        #expect(released == nil)
        #expect(runtime.capability(.debugWorkspace) == nil)
        #expect(try runtime.snapshot(for: .debug).activity.activeResourceCount == 0)

        let second = try #require(
            try await runtime.activateCapability(.debugWorkspace) as? DebugModuleCapability
        )
        #expect(ObjectIdentifier(second.javaFeature) != firstJavaID)
        #expect(recorder.factoryCalls == 2)
        #expect(recorder.graphCalls == 2)
    }

    private func workspaceFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .workspace, displayName: "Workspace", scope: .workspace)) {
            EmptyModule(id: .workspace, name: "Workspace")
        }
    }

    private func languageFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .languageIntelligence, displayName: "Language", scope: .workspace)) {
            EmptyModule(id: .languageIntelligence, name: "Language")
        }
    }

    private func executionFactory() -> ModuleFactory {
        ModuleFactory(manifest: ModuleManifest(id: .execution, displayName: "Execution", scope: .workspace)) {
            EmptyModule(id: .execution, name: "Execution")
        }
    }
}

@MainActor
private final class RecordingTransport: DebugAdapterTransport, DebugAdapterChildTransportProviding {
    private(set) var isRunning = false
    var onData: ((Data) -> Void)?
    var onErrorOutput: ((Data) -> Void)?
    var onTermination: ((Int) -> Void)?
    private(set) var sentData: [Data] = []
    private(set) var children: [RecordingTransport] = []
    private(set) var stopCalls = 0

    func start(rootURL: URL) throws {
        isRunning = true
    }

    func send(_ data: Data) throws {
        sentData.append(data)
    }

    func stop() {
        stopCalls += 1
        isRunning = false
    }

    func makeChildTransport() -> (any DebugAdapterTransport)? {
        let child = RecordingTransport()
        children.append(child)
        return child
    }

    func emitJSON(_ object: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        onData?(frame)
    }

    func request(named command: String) -> [String: Any]? {
        messages.first {
            $0["type"] as? String == "request" && $0["command"] as? String == command
        }
    }

    func response(to requestSequence: Int) -> [String: Any]? {
        messages.first {
            $0["type"] as? String == "response"
                && $0["request_seq"] as? Int == requestSequence
        }
    }

    private var messages: [[String: Any]] {
        sentData.compactMap { data in
            guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            return try? JSONSerialization.jsonObject(
                with: data.subdata(in: separator.upperBound..<data.endIndex)
            ) as? [String: Any]
        }
    }
}

@MainActor private final class Recorder {
    var factoryCalls = 0
    var graphCalls = 0
    weak var latestGraph: TestGraph?
}

@MainActor private final class TestGraph: DebugServiceGraph {
    let javaFeatureTarget: any JavaDebugFeatureTarget = TestJavaDebugFeatureTarget()
    let genericFeatureTarget: any GenericDebugFeatureTarget = TestGenericDebugFeatureTarget()
    var hasActiveDebugWork = false
    func activate(context: ModuleContext) {}
    func prepareForSleep() async throws {}
    func stop() async {}
}

@MainActor private final class TestJavaDebugFeatureTarget: JavaDebugFeatureTarget {}
@MainActor private final class TestGenericDebugFeatureTarget: GenericDebugFeatureTarget {}

@MainActor private final class EmptyModule: LitheModule {
    let manifest: ModuleManifest
    init(id: ModuleID, name: String) {
        manifest = ModuleManifest(id: id, displayName: name, scope: .workspace)
    }
    func activate(context: ModuleContext) async throws {}
    func prepareForSleep() async throws {}
    func sleep() async {}
    func shutdown() async {}
    func exportedCapabilities() -> [ModuleCapabilityID: AnyObject] { [:] }
}
