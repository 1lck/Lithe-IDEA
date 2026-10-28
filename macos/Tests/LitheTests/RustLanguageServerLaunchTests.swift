import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@MainActor
struct RustLanguageServerLaunchTests {
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

    private func read(_ name: String, _ root: URL) -> Any? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name + ".json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // macOS developer tools already provide Python; this explicit integration
    // fixture speaks framed JSON-RPC and accepts the JVM argv without a JDK.
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
        send({'jsonrpc':'2.0','id':message['id'],'result':{'capabilities':{'experimental':{'litheFunctions':{'version':2,'functions':[{'id':'snapshot.refresh'}]}}}}})
    elif method == 'initialized':
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
