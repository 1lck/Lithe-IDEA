import Combine
import Foundation
import Testing
import LitheModuleAPI
import LitheTerminalModule
@testable import Lithe

/// Uses the production AppModel terminal owner and a real native PTY. All files
/// and processes belong to this test; user profiles and installed plugins are untouched.
@MainActor
struct PluginTerminalNativeTests {
    @Test
    func displayContextBudgetKeepsUnicodeAndNeverRetainsControlSequences() {
        let native = MacTerminalTransport(scrollbackLines: 100)
        native.view.feed(text: "older\r\n\u{1b}[31m中文😀\u{1b}[0m\r\n")
        #expect(native.displayText(maximumBytes: 0).isEmpty)
        let suffix = native.displayText(maximumBytes: 8)
        #expect(suffix == "文😀\n")
        #expect(suffix.utf8.count == 8)
        #expect(!suffix.contains("\u{1b}"))
        #expect(!suffix.contains("�"))
        #expect(native.displayText(maximumBytes: 4) == "\n")
        native.stop()
    }

    @Test
    func nativeCreateCloseAndReopenRestoreDisplayWithoutReplayingInput() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plugin-terminal-native-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(), settings = AppSettings(store: MemoryStore())
        let model = AppModel(settings: settings, services: MacServiceContainer(store: store, settings: settings, moduleLaunchMode: .safeMode).services)
        let native = MacTerminalTransport(scrollbackLines: 100)
        let terminals = TerminalFeatureModel(terminalFactory: { native })
        model.cacheModuleCapability(TerminalModuleCapability(feature: terminals), id: .terminalWorkspace, moduleID: .terminal)
        model.workspaceSessionCoordinator.beginWorkspace(at: root)
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: model, rootURL: root, remote: nil)
        let metadata = PluginWorkspaceHostService(contexts: contexts,
            backendStateDirectory: { _ in root.appendingPathComponent("state") }, rootIDSecret: { Data("test".utf8) })
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        let service = PluginTerminalHostService(contexts: contexts, metadata: metadata)
        dispatcher.register(service)
        dispatcher.beginSession(pluginID: "native-test", hostServices: Array(service.methods))
        let consentShown = TestGate()
        let consent = model.hostMessages.$visible.sink { entries in
            guard let entry = entries.first else { return }
            consentShown.open()
            Task { @MainActor [weak model] in model?.hostMessages.choose(entry.id, index: 0) }
        }
        func request(_ method: String, _ params: [String: ToolingJSONValue]) -> PluginHostRequest {
            var params = params
            params["context"] = .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)])
            return PluginHostRequest(id: UUID().uuidString, method: "lithe/host/terminal/\(method)", service: "terminal", params: .object(params))
        }
        do {
            // A fixed explicit script supplies real output and then blocks in read.
            // Reopening creates a fresh process; history must never be sent to stdin.
            let created = try await dispatcher.dispatch(request("create", [
                "executable": .string("/bin/sh"), "arguments": .array([.string("-c"), .string("printf 'native-history-marker\\n'; read line; printf 'input:%s\\n' \"$line\"; read next")]),
                "show": .bool(false), "retainedContextBytes": .integer(128),
            ]), pluginID: "native-test").get()
            guard case .object(let result) = created, case .string(let id)? = result["terminalID"] else {
                throw PluginHostArguments.invalid
            }
            try #require(consentShown.isOpen)
            try #require(await eventually { native.displayText(maximumBytes: 128).contains("native-history-marker") })
            let firstSession = try #require(model.terminalSessions.first)
            _ = try await dispatcher.dispatch(request("close", ["terminalID": .string(id)]), pluginID: "native-test").get()
            #expect(!firstSession.isRunning)
            #expect(model.terminalSessions.isEmpty)
            _ = try await dispatcher.dispatch(request("reopen", ["terminalID": .string(id), "show": .bool(false)]), pluginID: "native-test").get()
            let secondSession = try #require(model.terminalSessions.first)
            #expect(secondSession.id != firstSession.id)
            try #require(await eventually {
                native.displayText(maximumBytes: 512).components(separatedBy: "native-history-marker").count == 3
            })
            #expect(!native.displayText(maximumBytes: 512).contains("input:"))
            try native.send(Data("manual-input\n".utf8))
            try #require(await eventually { native.displayText(maximumBytes: 512).contains("input:manual-input") })
            _ = try await dispatcher.dispatch(request("dispose", ["terminalID": .string(id)]), pluginID: "native-test").get()
            #expect(model.terminalSessions.isEmpty)
        } catch {
            consent.cancel(); model.hostMessages.dismissAll(.cancelled)
            dispatcher.endSession(pluginID: "native-test"); contexts.close(owner: model)
            await terminals.stopAllSessionsAndWait()
            throw error
        }
        consent.cancel(); model.hostMessages.dismissAll(.cancelled)
        dispatcher.endSession(pluginID: "native-test"); contexts.close(owner: model)
        await terminals.stopAllSessionsAndWait()
        #expect(!native.isRunning)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(5)
        while clock.now < deadline {
            if condition() { return true }
            // test-stability: allow(swift-real-sleep) reason: the real PTY output is external I/O without a test-owned scheduler; monotonic polling is locally bounded to five seconds.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private final class MemoryStore: KeyValueStore {
        var values: [String: Any] = [:]
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func object(forKey key: String) -> Any? { values[key] }
        func string(forKey key: String) -> String? { values[key] as? String }
        func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
    }
}
