import Foundation
import LitheModuleAPI
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@MainActor
struct RustLanguageServerLaunchTests {
    @Test
    func keymapProviderReadsOnlyItsSelectedSnapshotThroughRealSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-source-session-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("bindings".utf8).write(to: source.appendingPathComponent("bindings.json"))
        let executable = root.appendingPathComponent("server.py")
        try Self.keymapSourceServer.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let methods = ["lithe/host/keymapImport/listInputs", "lithe/host/keymapImport/readChunk"]
        let dispatcher = PluginHostServiceDispatcher(contexts: PluginWorkspaceContexts())
        let service = MacKeymapImportHostService()
        dispatcher.register(service)
        let pluginID = "dev.lithe.fixture.import"
        let hostSession = dispatcher.beginSession(pluginID: pluginID, hostServices: methods)
        let session = LanguageServerRuntimeSession(providerID: "fixture", executableURL: executable,
            arguments: [], environment: [:], initializeTimeout: 5, shutdownTimeout: 0.1,
            core: RustCoreBridge(), pluginID: pluginID, role: .backend, hostServices: methods,
            keymapImportProviders: ["first"])
        defer { session.stop(); dispatcher.endSession(pluginID: pluginID) }
        session.onHostRequest = { [weak session] request in
            dispatcher.handle(request, pluginID: pluginID, sessionID: hostSession) { result in
                session?.respond(to: request.id, with: result)
            }
        }
        session.onHostRequestCancelled = { requestID in
            dispatcher.cancel(hostRequestID: requestID, pluginID: pluginID, sessionID: hostSession)
        }
        let ready = TestGate()
        session.onStateChange = { state in if case .ready = state { ready.open() } }
        try session.start(rootURL: root, workspaceFingerprint: nil)
        try #require(await ready.waitUntilOpen(timeout: .seconds(5)))
        let manifestURL = DeclarativePluginTestSupport.repositoryRoot
            .appendingPathComponent("shared/contracts/plugins/v1/fixtures/keymap-import-provider.plugin.json")
        let plan = try RustKeymapImportOperations(core: RustCoreBridge()).planSources(
            manifest: Data(contentsOf: manifestURL), providerID: "first")
        let snapshot = try MacKeymapImportSnapshot(root: source, plan: plan)
        let token = service.snapshots.insert(snapshot, pluginID: pluginID, sessionID: hostSession, providerID: "first")
        let response = try await session.keymapImportRequest(providerID: "first", snapshotID: token, timeout: 5)
        guard case .object(let value) = response, case .object(let raw)? = value["response"],
              case .object(let payload)? = raw["result"] else {
            Issue.record("Provider response was not returned")
            return
        }
        #expect(payload["bindings"] == .array([.object([
            "commandID": .string("find-next"), "keys": .array([.object(["key": .string("f3"), "modifiers": .array([])])])
        ])]))
        #expect(await session.stopAndWait())
        dispatcher.endSession(pluginID: pluginID)
        let fileID = try #require(snapshot.files.first?.id)
        #expect(throws: (any Error).self) { try snapshot.read(fileID: fileID, offset: 0, maximumBytes: 1) }
    }

    @Test
    func shortcutImportRunsThroughManagedPluginSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-managed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("server.py")
        try Self.server.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let session = LanguageServerRuntimeSession(providerID: "fixture", executableURL: executable,
            arguments: [], environment: [:], initializeTimeout: 5, shutdownTimeout: 0.1,
            core: RustCoreBridge(), pluginID: "dev.lithe.fixture.import", role: .backend,
            keymapImportProviders: ["fixture"])
        defer { session.stop() }
        let ready = TestGate()
        session.onStateChange = { state in if case .ready = state { ready.open() } }
        try session.start(rootURL: root, workspaceFingerprint: nil)
        try #require(await ready.waitUntilOpen(timeout: .seconds(5)))
        #expect(session.keymapImportProviders == ["fixture"])
        let response = try await session.keymapImportRequest(providerID: "fixture", snapshotID: "snapshot-1", timeout: 2)
        guard case .object(let value) = response, case .object(let raw)? = value["response"],
              case .object(let payload)? = raw["result"] else {
            Issue.record("Provider response was not returned")
            return
        }
        #expect(payload["bindings"] == .array([]))
        #expect(await session.stopAndWait())
    }

    @Test
    func shortcutImportUsesNegotiatedPluginSessionThroughRustBridge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keymap-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("server.py")
        try Self.server.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let core = RustCoreBridge()
        let started = try core.lspStartServer(providerID: "fixture", pluginID: "dev.lithe.fixture.import",
            executableURL: executable, arguments: [], environment: [:], rootURL: root,
            workingDirectoryURL: root, keymapImportProviders: ["fixture"],
            initializeTimeout: 5, requestTimeout: 5, shutdownTimeout: 0.1).get()
        defer { core.stopLanguageServer(sessionID: started.sessionId); core.destroyLanguageServer(sessionID: started.sessionId) }
        var selected = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline && !selected {
            for event in core.pollLanguageServerEvents(sessionID: started.sessionId) where event.type == "keymapImportProviders" {
                if case .object(let object)? = event.result, case .array(let ids)? = object["providers"] {
                    selected = ids == [.string("fixture")]
                }
            }
            await Task.yield()
        }
        try #require(selected, "Plugin did not negotiate the declared import provider")
        if case .success = core.lspKeymapImportRequest(sessionID: started.sessionId, providerID: "other", snapshotID: "snapshot-1", timeout: 1) {
            Issue.record("Core accepted an unnegotiated provider")
        }
        let operation = try core.lspKeymapImportRequest(sessionID: started.sessionId, providerID: "fixture", snapshotID: "snapshot-1", timeout: 1).get()
        var received = false
        let responseDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < responseDeadline && !received {
            for event in core.pollLanguageServerEvents(sessionID: started.sessionId)
                where event.type == "requestCompleted" && event.operationID == operation.operationId {
                guard case .object(let result)? = event.result, case .object(let value)? = result["value"],
                      case .object(let response)? = value["response"], case .object(let payload)? = response["result"] else { continue }
                received = payload["bindings"] == .array([])
            }
            await Task.yield()
        }
        #expect(received)
        let sent = try #require(read("keymap-import", root) as? [String: Any])
        let params = try #require(sent["params"] as? [String: String])
        #expect(params == ["providerID": "fixture", "snapshotID": "snapshot-1"])
    }

    @Test(arguments: [false, true])
    func startupMapsIdentityConfigurationServicesAndJdtContextThroughCore(useJdt: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-core-launch-\(UUID().uuidString)")
        let installed = root.appendingPathComponent("installed")
        let configuration = installed.appendingPathComponent("config_arm64")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configText = "osgi.bundles.defaultStartLevel=4\n"
        try configText.write(to: configuration.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("runtime.py")
        try Self.server.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let launcher = installed.appendingPathComponent("plugins/equinox.jar")
        let lombok = installed.appendingPathComponent("lombok.jar")
        let extensionJar = installed.appendingPathComponent("extension.jar")
        let core = RustCoreBridge()
        let plugin = "dev.lithe.fixture.launch"
        let started = try core.startPluginLanguageServer(
            pluginID: plugin, providerID: useJdt ? "java" : "test-plugin",
            executableURL: useJdt ? root.appendingPathComponent("must-not-be-launched") : executable,
            arguments: useJdt ? ["-jar", launcher.path] : [], environment: [:], rootURL: root,
            initializationOptions: .object(["fixtureOption": .string("preserved")]),
            workspaceConfiguration: .object(["fixture": .object(["value": .string("configured")])]),
            hostServices: ["credentials"],
            hostIntegrationLaunch: useJdt ? .init(runtimeExecutableURL: executable, coreLaunch: .jdt(.init(
                launcherJarURL: launcher, configurationDirectoryURL: configuration, lombokAgentURL: lombok,
                javaExtensionBundleURLs: [extensionJar]))) : nil,
            cacheDirectoryURL: cache, workspaceFingerprint: "workspace-v1", mavenContext: nil, javaGradle: nil,
            initializeTimeout: 5, requestTimeout: 5, shutdownTimeout: 0.1
        ).get()
        defer { core.stopLanguageServer(sessionID: started.sessionID); core.destroyLanguageServer(sessionID: started.sessionID) }
        var ready = false, hostRequest = false, fingerprintObserved = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        // Core exposes a poll boundary; observe real process replies under a
        // monotonic deadline rather than guessing when the backend has started.
        while ContinuousClock.now < deadline {
            for event in core.pollLanguageServerEvents(sessionID: started.sessionID) {
                if event.type == "stateChanged", event.state == "ready" { ready = true }
                if event.message == "Java language service process started", let detail = event.detail?.data(using: .utf8),
                   let fields = try? JSONSerialization.jsonObject(with: detail) as? [String: Any] {
                    fingerprintObserved = fields["workspaceFingerprintPresent"] as? Bool == true
                }
                if event.type == "hostRequest" {
                    guard case .object(let value)? = event.result else {
                        Issue.record("Host request was not an object")
                        continue
                    }
                    #expect(value["service"] == .string("credentials"))
                    #expect(event.method == "lithe/host/credentials/get")
                    guard case .string(let id)? = value["hostRequestID"] else {
                        Issue.record("Host request had no ID")
                        continue
                    }
                    try core.respondToPluginHostRequest(sessionID: started.sessionID, hostRequestID: id,
                        outcome: .success(.object(["value": .string("fixture-only")]))).get()
                    hostRequest = true
                }
            }
            if ready && hostRequest && read("configuration", root) != nil && read("credential", root) != nil { break }
            await Task.yield()
        }
        try #require(ready && hostRequest, "Backend did not reach ready and receive the granted service")
        let arguments = try #require(read("argv", root) as? [String])
        if useJdt {
            #expect(fingerprintObserved)
            #expect(arguments.contains("-javaagent:" + lombok.path))
            #expect(arguments.contains(launcher.path))
            let configIndex = try #require(arguments.firstIndex(of: "-configuration"))
            let writable = URL(fileURLWithPath: arguments[configIndex + 1])
            #expect(writable.path.hasPrefix(cache.path + "/jdtls-configuration/"))
            #expect(try String(contentsOf: writable.appendingPathComponent("config.ini"), encoding: .utf8) == configText)
            let dataIndex = try #require(arguments.firstIndex(of: "-data"))
            #expect(arguments[dataIndex + 1].hasPrefix(cache.path + "/jdtls/"))
        }
        let initialize = try #require(read("initialize", root) as? [String: Any])
        let params = try #require(initialize["params"] as? [String: Any])
        let options = try #require(params["initializationOptions"] as? [String: Any])
        #expect(options["fixtureOption"] as? String == "preserved")
        if useJdt { #expect((options["bundles"] as? [String])?.contains(extensionJar.path) == true) }
        let configured = try #require(read("configuration", root) as? [String: Any])
        if useJdt {
            // JDT owns workspace/configuration sections; an unrelated section
            // returns null. Generic plugins read the forwarded plugin config.
            #expect((configured["result"] as? [Any])?.first is NSNull)
        } else {
            #expect(((configured["result"] as? [[String: String]])?.first)?["value"] == "configured")
        }
        let credential = try #require(read("credential", root) as? [String: Any])
        #expect((credential["result"] as? [String: String])?["value"] == "fixture-only")
        // A function call with the exact plugin owner must be accepted, while
        // another plugin cannot use the same backend's negotiated function.
        _ = try core.lspFunctionRequest(sessionID: started.sessionID, pluginID: plugin,
            functionID: "snapshot.refresh", params: .object([:]), timeout: 1).get()
        if case .success = core.lspFunctionRequest(sessionID: started.sessionID, pluginID: "dev.lithe.other",
            functionID: "snapshot.refresh", params: .object([:]), timeout: 1) {
            Issue.record("Core accepted another plugin's function request")
        }
        #expect(try String(contentsOf: configuration.appendingPathComponent("config.ini"), encoding: .utf8) == configText)
        #expect(try FileManager.default.contentsOfDirectory(atPath: configuration.path) == ["config.ini"])
    }

    @Test(arguments: [LanguageServerLogRole.languageServer, .vcs, .build, .toolchain, .backend])
    func explicitRolesRouteCoreFactsAndDiagnosticCommands(role: LanguageServerLogRole) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("server.py")
        try Self.server.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let clock = LogRoleClock()
        let store = MacLogStore(defaultDirectory: root.appendingPathComponent("logs"), diagnosticNow: clock.now)
        let bridge = RustCoreBridge(coreLogSink: store,
            registerLogSession: { id, channel in store.registerSession(id, channel: channel) },
            releaseLogSession: { id in store.releaseSession(id) })
        let core = bridge.loggingRuntime(role: role, logSubject: "git", pluginID: "dev.lithe.fixture")
        let resolvedSubject = try bridge.resolveEngineLogSubject(providerID: "c++")
        let subject = try #require(resolvedSubject)
        let channel = role == .languageServer ? "lsp/" + subject.rawValue : role == .vcs ? "vcs/git" : "plugins/dev.lithe.fixture/host"
        // New sessions inherit the already active category. Unmatched categories
        // stay off; changing and expiring it writes the corresponding trace gate.
        await store.configureDiagnostic(category: "git", enabled: true)
        let start = try core.startPluginLanguageServer(pluginID: "dev.lithe.fixture", providerID: "c++",
            executableURL: executable, arguments: [], environment: [:], rootURL: root, initializationOptions: nil,
            initializeTimeout: 5, requestTimeout: 5, shutdownTimeout: 0.1).get()
        defer { core.stopLanguageServer(sessionID: start.sessionID); core.destroyLanguageServer(sessionID: start.sessionID) }
        var logs: [CoreLogRecord] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let events = core.pollLanguageServerEvents(sessionID: start.sessionID)
            for event in events { if let log = event.coreLog { logs.append(log); core.emitCoreLog(log) } }
            if logs.contains(where: { $0.event.hasSuffix("message.logged") }) { break }
            await Task.yield()
        }
        #expect(logs.contains { $0.channel == channel && $0.event.hasSuffix("message.logged") })
        #expect(logs.contains { $0.channel == channel && $0.event.hasSuffix("session.updated") })
        await store.configureDiagnostic(category: "git", enabled: true)
        if role == .vcs { #expect(await waitForTrace("verbose", root: root)) }
        else { #expect(read("trace", root) == nil) }
        await store.configureDiagnostic(category: nil, enabled: true)
        #expect(await waitForTrace("verbose", root: root))
        clock.advance(901)
        try await store.flush()
        #expect(await waitForTrace("off", root: root))
        let collection = try await store.collect(query: .init(session: "all"))
        #expect(collection.files.contains { $0.relativePath.hasSuffix(channel + ".log") })
        #expect(collection.content.contains("event=" + (role == .languageServer ? "lsp" : role == .vcs ? "vcs" : "plugins.host") + ".message.logged"))
        core.stopLanguageServer(sessionID: start.sessionID)
        core.destroyLanguageServer(sessionID: start.sessionID)
        await store.finishSession()
    }

    @Test
    func hostFactsForUnsafeProviderUseTheCoreSessionChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("server.py")
        try Self.server.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let recorder = TypedLogRecorder()
        let bridge = RustCoreBridge(coreLogSink: recorder)
        let descriptor = LanguageProviderDescriptor(id: "c++", displayName: "Fixture", fileExtensions: ["cpp"],
            capabilities: [.languageServer], activationPolicy: .onDemand)
        let session = LanguageServerRuntimeSession(providerID: descriptor.id, executableURL: executable,
            arguments: [], environment: [:], initializeTimeout: 5, shutdownTimeout: 0.1, core: bridge)
        let manager = LanguageToolingSessionManager(catalog: .init(descriptors: [descriptor]), logSink: recorder,
            resolveLogSubject: { try bridge.resolveEngineLogSubject(providerID: $0) },
            runtimes: [LogChannelRuntime(descriptor: descriptor, session: session)],
            workspaceFingerprintProvider: { _, _ in "channel-fingerprint" },
            workspaceStateCleaner: { _, _, _ in 0 })
        defer { manager.stopAllLanguageServers() }
        manager.onLogEvent = { recorder.emit($0) }
        let ready = TestGate()
        manager.onLanguageServerStateChange = { _, state, _ in if state == .ready { ready.open() } }
        try manager.startLanguageServer(providerID: descriptor.id, rootURL: root)
        try #require(await ready.waitUntilOpen(timeout: .seconds(5)))
        // Exercise the existing host-owned issue callback at its typed boundary.
        session.onLogIssue?(true, "discovery", "tool_not_found", nil, nil)
        session.onLogIssue?(false, "processStart", "start_failed", 17, nil)
        let resolvedSubject = try bridge.resolveEngineLogSubject(providerID: descriptor.id)
        let channel = "lsp/" + (try #require(resolvedSubject)).rawValue
        #expect(channel.hasPrefix("lsp/invalid-"))
        #expect(recorder.coreRecords.contains { $0.event == "lsp.session.updated" && $0.channel == channel })
        #expect(recorder.coreRecords.contains { $0.event == "lsp.protocol.initialized" && $0.channel == channel })
        #expect(recorder.events.compactMap { $0 as? LspSessionStageChanged }.count == 3)
        #expect(recorder.events.contains { $0 is LspCacheCleaned })
        #expect(recorder.events.contains { $0 is LspSessionDegradationReceived })
        #expect(recorder.events.contains { $0 is LspSessionIssueFailed })
        #expect(recorder.events.allSatisfy { $0.channel.rawValue == channel })
        manager.stopAllLanguageServers()
        #expect(await session.stopAndWait())
    }

    private func waitForTrace(_ value: String, root: URL) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if read("trace", root) as? String == value { return true }
            await Task.yield()
        }
        return false
    }

    private func read(_ name: String, _ root: URL) -> Any? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    // macOS developer tools already provide Python; this explicit integration
    // fixture speaks framed JSON-RPC and accepts the JVM argv without a JDK.
    private static let keymapSourceServer = #"""
#!/usr/bin/python3
import json, sys
def send(value):
    body = json.dumps(value).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n' % len(body)).encode() + body)
    sys.stdout.buffer.flush()
while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line == b'\r\n': break
        key, value = line.decode().split(':', 1)
        headers[key.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
    method = message.get('method')
    if method == 'initialize':
        send({'jsonrpc':'2.0','id':message['id'],'result':{'capabilities':{'experimental':{
            'litheFunctions':{'version':3,'functions':[]},
            'litheKeymapImport':{'version':1,'providers':['first']}}}}})
    elif method == 'lithe/keymap/import':
        request_id = message['id']
        params = message['params']
        send({'jsonrpc':'2.0','id':'list','method':'lithe/host/keymapImport/listInputs','params':params})
    elif message.get('id') == 'list':
        files = message['result']['files']
        send({'jsonrpc':'2.0','id':'read','method':'lithe/host/keymapImport/readChunk','params':{
            **params, 'fileID':files[0]['id'], 'offset':0, 'maximumBytes':8}})
    elif message.get('id') == 'read':
        keys = [{'key':'f3','modifiers':[]}] if message['result']['data'] == 'YmluZGluZ3M=' else []
        send({'jsonrpc':'2.0','id':request_id,'result':{'bindings':[{'commandID':'find-next','keys':keys}]}})
    elif method == 'exit': break
    elif method and 'id' in message: send({'jsonrpc':'2.0','id':message['id'],'result':None})
"""#

    private static let server = #"""
#!/usr/bin/python3
import json, pathlib, sys
root = pathlib.Path(__file__).parent

def record(name, value):
    tmp = root / (name + '.tmp')
    tmp.write_text(json.dumps(value))
    tmp.replace(root / (name + '.json'))

def send(value):
    body = json.dumps(value).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n' % len(body)).encode() + body)
    sys.stdout.buffer.flush()

record('argv', sys.argv[1:])
while True:
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line == b'\r\n': break
        key, value = line.decode().split(':', 1)
        headers[key.lower()] = value.strip()
    message = json.loads(sys.stdin.buffer.read(int(headers['content-length'])))
    method = message.get('method')
    if method == 'initialize':
        record('initialize', message)
        experimental = {'litheFunctions':{'version':2,'functions':[{'id':'snapshot.refresh'}]}}
        offered = message.get('params', {}).get('capabilities', {}).get('experimental', {}).get('litheKeymapImport')
        if offered: experimental['litheKeymapImport'] = {'version':1, 'providers':offered['providers']}
        send({'jsonrpc':'2.0','id':message['id'],'result':{'capabilities':{'experimental':experimental}}})
    elif method == '$/setTrace':
        record('trace', message['params']['value'])
    elif method == 'lithe/keymap/import':
        record('keymap-import', message)
        send({'jsonrpc':'2.0','id':message['id'],'result':{'bindings':[]}})
    elif method == 'initialized':
        send({'jsonrpc':'2.0','method':'window/logMessage','params':{'type':3,'message':'fixture diagnostic'}})
        send({'jsonrpc':'2.0','method':'language/status','params':{'type':'ServiceReady'}})
        send({'jsonrpc':'2.0','id':'configuration','method':'workspace/configuration','params':{'items':[{'section':'fixture'}]}})
        send({'jsonrpc':'2.0','id':'credential','method':'lithe/host/credentials/get','params':{'key':'fixture'}})
    elif method == 'exit':
        break
    elif method and 'id' in message:
        send({'jsonrpc':'2.0','id':message['id'],'result':None})
    elif message.get('id') in ('configuration','credential'):
        record(message['id'], message)
"""#
}

private final class LogRoleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@MainActor
private final class LogChannelRuntime: LanguageProviderRuntime {
    init(descriptor: LanguageProviderDescriptor, session: LanguageServerRuntimeSession) {
        self.descriptor = descriptor; self.session = session
    }
    let descriptor: LanguageProviderDescriptor
    let session: LanguageServerRuntimeSession
    var supportsLanguageServerSession: Bool { true }
    func makeLanguageServerSession() -> (any LanguageServerSession)? { session }
}
