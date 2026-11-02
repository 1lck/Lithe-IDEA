import AppKit
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
        let userNative = MacTerminalTransport(scrollbackLines: 100)
        var createsUserTerminal = true
        let terminals = TerminalFeatureModel(terminalFactory: {
            if createsUserTerminal { createsUserTerminal = false; return userNative }
            return native
        })
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
            let user = try await terminals.createProcessSessionAsync(TerminalProcessLaunch(title: "User terminal",
                executablePath: "/bin/sh", arguments: ["-c", "read line"], workingDirectory: root.path), workspaceURL: root)
            model.terminalPlacementFeature.registerSession(user.session.id)
            model.showToolWindow(.terminal)
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
            #expect(model.activeTerminalSessionID == user.session.id)
            #expect(model.activeToolTerminalSession === user.session)
            #expect(model.toolTerminalSessions.map(\.id) == [user.session.id])
            try #require(await eventually { native.displayText(maximumBytes: 128).contains("native-history-marker") })
            let firstSession = try #require(model.terminalSessions.first { $0 !== user.session })
            _ = try await dispatcher.dispatch(request("close", ["terminalID": .string(id)]), pluginID: "native-test").get()
            #expect(!firstSession.isRunning)
            #expect(model.terminalSessions.map(\.id) == [user.session.id])
            _ = try await dispatcher.dispatch(request("reopen", ["terminalID": .string(id), "show": .bool(false)]), pluginID: "native-test").get()
            let secondSession = try #require(model.terminalSessions.first { $0 !== user.session })
            #expect(secondSession.id != firstSession.id)
            #expect(model.activeTerminalSessionID == user.session.id)
            #expect(model.activeToolTerminalSession === user.session)
            #expect(model.toolTerminalSessions.map(\.id) == [user.session.id])
            try #require(await eventually {
                native.displayText(maximumBytes: 512).components(separatedBy: "native-history-marker").count == 3
            })
            #expect(!native.displayText(maximumBytes: 512).contains("input:"))
            try native.send(Data("manual-input\n".utf8))
            try #require(await eventually { native.displayText(maximumBytes: 512).contains("input:manual-input") })
            _ = try await dispatcher.dispatch(request("show", ["terminalID": .string(id)]), pluginID: "native-test").get()
            #expect(model.activeToolTerminalSession === secondSession)
            #expect(model.toolTerminalSessions.map(\.id) == [user.session.id, secondSession.id])
            _ = try await dispatcher.dispatch(request("dispose", ["terminalID": .string(id)]), pluginID: "native-test").get()
            #expect(model.terminalSessions.map(\.id) == [user.session.id])
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
        #expect(!userNative.isRunning)
    }

    @Test(arguments: [0, 8], [false, true])
    func tabCloseAndNaturalExitReleaseNativeBufferBeforeDeliveringExit(bytes: Int, naturalExit: Bool) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plugin-terminal-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(store: MemoryStore())
        let model = AppModel(settings: settings, services: MacServiceContainer(store: MemoryStore(), settings: settings, moduleLaunchMode: .safeMode).services)
        weak var originalNative: MacTerminalTransport?
        let terminals = TerminalFeatureModel(terminalFactory: {
            let native = MacTerminalTransport(scrollbackLines: 100)
            originalNative = native
            return native
        })
        model.cacheModuleCapability(TerminalModuleCapability(feature: terminals), id: .terminalWorkspace, moduleID: .terminal)
        model.workspaceSessionCoordinator.beginWorkspace(at: root)
        let contexts = PluginWorkspaceContexts()
        let context = contexts.open(owner: model, rootURL: root, remote: nil)
        let metadata = PluginWorkspaceHostService(contexts: contexts,
            backendStateDirectory: { _ in root.appendingPathComponent("state") }, rootIDSecret: { Data("test".utf8) })
        let dispatcher = PluginHostServiceDispatcher(contexts: contexts)
        dispatcher.register(PluginTerminalHostService(contexts: contexts, metadata: metadata))
        dispatcher.beginSession(pluginID: "release-test", hostServices: ["create", "onExit", "reopen", "dispose"].map { "lithe/host/terminal/" + $0 })
        let exited = TestGate()
        dispatcher.subscriptions.deliver = { _, _ in exited.open() }
        let consent = model.hostMessages.$visible.sink { entries in
            guard let entry = entries.first else { return }
            Task { @MainActor [weak model] in model?.hostMessages.choose(entry.id, index: 0) }
        }
        func request(_ method: String, _ params: [String: ToolingJSONValue]) -> PluginHostRequest {
            var params = params
            params["context"] = .object(["contextID": .string(context.contextID), "generation": .integer(context.generation)])
            return PluginHostRequest(id: UUID().uuidString, method: "lithe/host/terminal/\(method)", service: "terminal", params: .object(params))
        }
        do {
            let created = try await dispatcher.dispatch(request("create", [
                "executable": .string("/bin/sh"), "arguments": .array([.string("-c"), .string("if [ ! -f started ]; then printf 'discard-secret-prefix\\nrecent\\n'; : > started; fi; read line")]),
                "retainedContextBytes": .integer(bytes), "show": .bool(false),
            ]), pluginID: "release-test").get()
            guard case .object(let result) = created, case .string(let id)? = result["terminalID"] else { throw PluginHostArguments.invalid }
            _ = try await dispatcher.dispatch(request("onExit", ["terminalID": .string(id)]), pluginID: "release-test").get()
            try #require(await eventually { originalNative?.displayText(maximumBytes: 128).contains("recent") == true })
            weak var session = model.terminalSessions.first
            if naturalExit { try originalNative?.send(Data("\n".utf8)) }
            else { model.closeTerminalSession(try #require(session)) }
            try #require(await exited.waitUntilOpen())
            #expect(model.terminalSessions.isEmpty)
            #expect(session == nil, "A closed handle must not retain its native session")
            #expect(originalNative == nil, "Even a zero-byte history budget must release the full renderer")
            let reopened = try await dispatcher.dispatch(request("reopen", ["terminalID": .string(id), "show": .bool(false)]), pluginID: "release-test").get()
            guard case .object(let restored) = reopened else { throw PluginHostArguments.invalid }
            #expect(restored["restoredContextBytes"] == .integer(bytes == 0 ? 0 : 8))
            #expect(originalNative?.displayText(maximumBytes: 512).contains("discard-secret-prefix") == false)
            _ = try await dispatcher.dispatch(request("dispose", ["terminalID": .string(id)]), pluginID: "release-test").get()
        } catch {
            consent.cancel(); model.hostMessages.dismissAll(.cancelled)
            dispatcher.endSession(pluginID: "release-test"); contexts.close(owner: model)
            await terminals.stopAllSessionsAndWait()
            throw error
        }
        consent.cancel(); model.hostMessages.dismissAll(.cancelled)
        dispatcher.endSession(pluginID: "release-test"); contexts.close(owner: model)
        await terminals.stopAllSessionsAndWait()
    }

    @Test
    func longExecutionConsentKeepsEveryArgumentAndDirectoryInspectableAndCancellable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("plugin-terminal-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings(store: MemoryStore())
        let model = AppModel(settings: settings, services: MacServiceContainer(store: MemoryStore(), settings: settings, moduleLaunchMode: .safeMode).services)
        model.workspaceSessionCoordinator.beginWorkspace(at: root)
        let presented = TestGate(), finished = TestGate()
        let observation = model.hostMessages.$visible.sink { if !$0.isEmpty { presented.open() } }
        defer { observation.cancel(); model.hostMessages.dismissAll(.cancelled) }
        let arguments = [String(repeating: "长参数", count: 1800), "last-argument\nwith-control"]
        let pending = Task { @MainActor in
            defer { finished.open() }
            let access = try await model.hostCreatePluginTerminal(PluginTerminalLaunch(pluginID: "consent-test", title: "Client",
                executable: "/bin/sh", arguments: arguments, workingDirectory: root, environment: [:], show: false), onExit: { _ in })
            await access.close()
        }
        defer { pending.cancel() }
        try #require(await presented.waitUntilOpen())
        let entry = try #require(model.hostMessages.visible.first)
        let details = try #require(entry.details)
        let document = PluginHostMessageDetailsScrollView(text: details)
        document.frame.size = NSSize(width: 300, height: 180)
        let text = try #require(document.documentView as? NSTextView)
        text.frame.size.width = 300
        #expect(text.string == details)
        #expect(!text.isEditable && text.isSelectable)
        #expect(document.hasVerticalScroller)
        let manager = try #require(text.layoutManager), container = try #require(text.textContainer)
        manager.ensureLayout(for: container)
        #expect(manager.usedRect(for: container).height > document.frame.height)
        let encoder = JSONEncoder()
        #expect(details.contains(String(decoding: try encoder.encode(arguments), as: UTF8.self)))
        #expect(details.contains(String(decoding: try encoder.encode(root.path), as: UTF8.self)))
        pending.cancel()
        try #require(await finished.waitUntilOpen())
        do { _ = try await pending.value; Issue.record("Cancelled consent started a terminal") }
        catch is CancellationError { }
        #expect(model.hostMessages.pendingCount == 0)
        #expect(model.terminalSessions.isEmpty)
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
