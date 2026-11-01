import Darwin
import Foundation
import Testing
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI

/// Real directories and the real Core; only the home directory and version probes are injected,
/// so no installed developer tool is read or run.
@Suite("macOS toolchain discovery")
struct MacToolchainDiscoveryTests {
    private static let pluginID = "dev.lithe.fixture.discovery"

    private static func manifest(complete: Bool = true) -> Data {
        let definition: [String: Any] = [
            "id": "compiler", "displayName": "Fixture compiler", "icon": ["host": "plugin"],
            "executableLayouts": [["path": "bin/compiler"]],
            "executables": [
                ["id": "home", "kind": "environment", "variable": "FIXTURE_HOME", "path": "bin/compiler"],
                ["id": "shell", "kind": "command", "command": "compiler"],
                ["id": "detected", "kind": "toolchain", "scope": "installed"]
            ],
            "version": ["arguments": ["--version"], "pattern": #"compiler (\d+(?:\.\d+)*)"#],
            "homeLayouts": [["match": "*.kit", "home": "Contents/Home"]],
            "discovery": [["root": ["kind": "home"], "pattern": "Kits/*"]],
            "homeVariable": "FIXTURE_HOME", "commands": ["compiler"], "wrappers": [], "exports": [],
            "pathPrepend": ["${home}/bin"], "launch": ["${executable}", "${arguments}"]
        ]
        var manifest: [String: Any] = [
            "schemaVersion": 2, "id": pluginID, "displayName": "Discovery fixture", "version": "1.0.0",
            "pluginAPIVersion": 3,
            "vendor": ["id": "org.example", "displayName": "Fixture publisher", "signatureRequirement": "publisherPackage"],
            "permissions": [], "toolDefinitions": [definition]
        ]
        if complete { manifest["requires"] = ["toolDefinitions": 1, "executableResolution": 2] }
        return (try? JSONSerialization.data(withJSONObject: manifest)) ?? Data()
    }

    private static func source(complete: Bool = true) -> ToolchainSettingsPluginSource {
        .init(pluginID: pluginID, name: "Discovery fixture", manifest: manifest(complete: complete), isEnabled: true,
              verifiedOfficial: true)
    }

    @Test func scannedHomesAreCheckedProbedAndTheHighestVersionIsSelected() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let newer = try root.installation("home/Kits/newer.kit/Contents/Home")
        let older = try root.installation("home/Kits/older.kit/Contents/Home")
        let broken = try root.installation("home/Kits/broken.kit/Contents/Home")
        let shell = try root.installation("shell-home")
        _ = try root.installation("home/Kits/plain/Contents/Home")
        _ = try root.installation("home/Kits/.hidden.kit/Contents/Home")
        try Data().write(to: root.url("home/Kits/notes.kit"))
        let inside = try root.installation("workspace/inside.kit/Contents/Home")
        try FileManager.default.createSymbolicLink(at: root.url("home/Kits/linked.kit"),
                                                   withDestinationURL: root.url("workspace/inside.kit"))
        let probes = DiscoveryProbes(outputs: [
            newer + "/bin/compiler": "compiler 21.0.1", older + "/bin/compiler": "compiler 17.0.2",
            shell + "/bin/compiler": "compiler 23.1"
        ])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source()],
            environment: ["FIXTURE_HOME": shell, "UNDECLARED": "/private"]))

        let detection = try #require(result.detections["compiler"])
        #expect(result.unchecked.isEmpty && result.diagnostics.isEmpty)
        #expect(Set(detection.installations.map(\.home)) == [newer, older])
        #expect(detection.installations.allSatisfy { $0.provider == "host:system" })
        #expect(detection.installations.first { $0.home == newer }?.version == "21.0.1")
        #expect(detection.installations.first { $0.home == newer }?.executable == newer + "/bin/compiler")
        // The home layout's suffix is shared by every kit; the scanned entry names the installation.
        #expect(detection.installations.first { $0.home == newer }?.location == root.path + "/home/Kits/newer.kit")
        #expect(detection.selected == newer && !detection.conflict)
        #expect(detection.skipped == [.init(home: broken, reason: "probeFailed")])
        #expect(detection.shell == [.init(variable: "FIXTURE_HOME", home: shell, executable: shell + "/bin/compiler",
                                          version: "23.1")])
        // Only homes Core checked are probed: never the project, an unmatched or hidden entry.
        let probed = probes.calls
        #expect(Set(probed.map(\.executable)) == Set([newer, older, broken, shell].map { $0 + "/bin/compiler" }))
        #expect(probed.allSatisfy { $0.arguments == ["--version"] })
        #expect(!probed.contains { $0.executable.hasPrefix(inside) })
    }

    @Test func equalHighestVersionsInDifferentHomesAreAConflict() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let first = try root.installation("home/Kits/first.kit/Contents/Home")
        let second = try root.installation("home/Kits/second.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [first + "/bin/compiler": "compiler 21", second + "/bin/compiler": "compiler 21.0"])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source()], environment: [:]))
        let detection = try #require(result.detections["compiler"])
        #expect(detection.installations.count == 2)
        #expect(detection.selected == nil && detection.conflict)
    }

    @Test func refusedDeclarationsAreReportedWithoutScanningOrProbing() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let home = try root.installation("home/Kits/only.kit/Contents/Home")
        let probes = DiscoveryProbes(outputs: [home + "/bin/compiler": "compiler 1"])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source(complete: false)], environment: [:]))
        #expect(result.detections.isEmpty && result.unchecked.isEmpty)
        #expect(result.diagnostics == [L10n.string("Installed toolchain declarations could not be checked for discovery.")])
        #expect(probes.calls.isEmpty)
    }

    /// The definition plugin as its own provider, as a version-manager plugin declares one. Its
    /// definition gains the project and global layers, where provider statements decide.
    private static func providerSource(providers: [String] = ["kits"]) throws -> ToolchainSettingsPluginSource {
        var manifest = try #require(try JSONSerialization.jsonObject(with: manifest()) as? [String: Any])
        var definitions = try #require(manifest["toolDefinitions"] as? [[String: Any]])
        let executables = try #require(definitions.first?["executables"] as? [[String: Any]])
        definitions[0]["executables"] = [["id": "project", "kind": "toolchain", "scope": "project"],
                                         ["id": "global", "kind": "toolchain", "scope": "global"]] + executables
        manifest["toolDefinitions"] = definitions
        manifest["requires"] = ["toolDefinitions": 1, "executableResolution": 2, "toolchainProviders": 1,
                                "backend": 2, "serverProcess": 1]
        manifest["permissions"] = ["backend.launch", "toolchains.provide"]
        manifest["toolchainProviders"] = providers.map { id in
            ["id": id, "displayName": id.capitalized, "tools": ["compiler"],
             "watchFiles": [["pattern": ".compiler-version", "reader": "native"]]] as [String: Any]
        }
        manifest["backend"] = ["launch": ["kind": "packaged", "path": "bin/kits"]]
        return .init(pluginID: pluginID, name: "Discovery fixture",
                     manifest: try JSONSerialization.data(withJSONObject: manifest), isEnabled: true, verifiedOfficial: true)
    }

    /// A provider reports an alias link; Core keeps the canonical home, the project
    /// requirement and the global one apart, and the installation joins the candidates.
    @Test func providerAnswersAreValidatedAndJoinTheCandidates() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let installed = try root.installation("manager/installs/compiler/21.0.1")
        try FileManager.default.createSymbolicLink(atPath: root.path + "/manager/installs/compiler/latest",
                                                   withDestinationPath: installed)
        let alias = root.path + "/manager/installs/compiler/latest"
        let versionFile = root.path + "/workspace/.compiler-version"
        try Data("21\n".utf8).write(to: URL(fileURLWithPath: versionFile))
        let globalFile = root.path + "/home/.compiler-version"
        try Data("21\n".utf8).write(to: URL(fileURLWithPath: globalFile))
        let queries = ProviderQueries { params in
            let project = params["workspace"] is [String: Any]
            let statements: [[String: Any]] = [
                ["tool": "compiler", "scope": "global", "source": globalFile, "request": "21", "installation": alias,
                 "kind": "declaration", "reader": "native"]
            ] + (project ? [["tool": "compiler", "scope": "project", "source": versionFile, "request": "21",
                              "installation": alias, "kind": "declaration", "reader": "native"]] : [])
            return ["installations": [["tool": "compiler", "version": "21.0.1", "home": alias]],
                    "statements": statements, "watch": [root.path + "/manager/installs"]]
        }
        let probes = DiscoveryProbes(outputs: [installed + "/bin/compiler": "compiler 21.0.1"])
        var discovery = discovery(root: root, probes: probes)
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: 3, rootID: "root-1") }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: [:]))

        let provider = Self.pluginID + ":kits"
        #expect(result.diagnostics.isEmpty)
        let detection = try #require(result.detections["compiler"])
        #expect(detection.installations.map(\.home) == [installed])
        #expect(detection.installations.first?.provider == provider)
        #expect(result.requirements["."]?["compiler"] == [.init(request: "21", source: versionFile, providerID: provider,
                                                                 home: installed, version: "21.0.1")])
        #expect(result.globalRequirements["compiler"] == [.init(request: "21", source: globalFile, providerID: provider,
                                                                 home: installed, version: "21.0.1")])
        #expect(result.watch == [root.path + "/manager/installs"])
        guard case .answered? = result.providerStates[provider] else {
            Issue.record("the provider should have answered")
            return
        }
        // Core resolves the same replies: the project requirement decides, not the page.
        #expect(result.unresolved.isEmpty)
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .project, outcome: .resolved(
            home: installed, executable: installed + "/bin/compiler", version: "21.0.1", provider: provider)))
        // A global query, then one round per directory. Every provider in a round shares its
        // generation, and every request has its own operation.
        let sent = queries.sent
        #expect(sent.count == 2)
        #expect(sent.first?["workspace"] is NSNull && sent.first?["context"] is NSNull)
        let workspace = try #require(sent.last?["workspace"] as? [String: Any])
        #expect(workspace["rootID"] as? String == "root-1" && workspace["directory"] as? String == ".")
        #expect(Set(sent.compactMap { $0["operationID"] as? String }).count == 2)
        #expect(Set(sent.compactMap { $0["generation"] as? Int }).count == 2)
    }

    /// A requirement nothing installs is reported and the next layer decides.
    @Test func anUninstalledRequirementIsUnmetAndTheNextLayerDecides() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let installed = try root.installation("manager/installs/compiler/21.0.1")
        let versionFile = root.path + "/workspace/.compiler-version"
        try Data("22\n".utf8).write(to: URL(fileURLWithPath: versionFile))
        let queries = ProviderQueries { params in
            let project = params["workspace"] is [String: Any]
            return ["installations": [["tool": "compiler", "version": "21.0.1", "home": installed]],
                    "statements": project ? [["tool": "compiler", "scope": "project", "source": versionFile,
                                              "request": "22", "installation": NSNull(), "kind": "declaration",
                                              "reader": "native"]] : [],
                    "watch": []]
        }
        let probes = DiscoveryProbes(outputs: [installed + "/bin/compiler": "compiler 21.0.1"])
        var discovery = discovery(root: root, probes: probes)
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: 3, rootID: "root-1") }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: [:]))

        let provider = Self.pluginID + ":kits"
        #expect(result.requirements["."]?["compiler"] == [.init(request: "22", source: versionFile, providerID: provider)])
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .automatic, outcome: .resolved(
            home: installed, executable: installed + "/bin/compiler", version: "21.0.1", provider: provider),
            unmet: ["22"]))
    }

    /// The window's context changed during one load: the round keeps the context it opened
    /// with, and a reply under the newer one is neither resolved nor shown for that directory.
    @Test func aReplyUnderAChangedContextIsLeftOutOfItsDirectory() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let installed = try root.installation("manager/installs/compiler/21.0.1")
        let versionFile = root.path + "/workspace/.compiler-version"
        try Data("21\n".utf8).write(to: URL(fileURLWithPath: versionFile))
        let queries = ProviderQueries { params in
            let project = params["workspace"] is [String: Any]
            return ["installations": [["tool": "compiler", "version": "21.0.1", "home": installed]],
                    "statements": project ? [["tool": "compiler", "scope": "project", "source": versionFile,
                                              "request": "21", "installation": installed, "kind": "declaration",
                                              "reader": "native"]] : [],
                    "watch": []]
        }
        let contexts = ContextGenerations(first: 3)
        let probes = DiscoveryProbes(outputs: [installed + "/bin/compiler": "compiler 21.0.1"])
        var discovery = discovery(root: root, probes: probes)
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        discovery.workspaceContext = { _, _ in .init(contextID: "context-1", generation: contexts.next(), rootID: "root-1") }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource(providers: ["kits", "other"])],
            environment: [:]))

        // Providers are asked in name order, so `kits` opened the round and `other` came under generation 4.
        let kits = Self.pluginID + ":kits"
        #expect(queries.sent.contains { ($0["context"] as? [String: Any])?["generation"] as? Int == 4 })
        #expect(result.requirements["."]?["compiler"] == [.init(request: "21", source: versionFile, providerID: kits,
                                                                 home: installed, version: "21.0.1")])
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .project, outcome: .resolved(
            home: installed, executable: installed + "/bin/compiler", version: "21.0.1", provider: kits)))
    }

    /// A saved pin decides alone in its directory, even one no provider was asked about. Its home
    /// is checked and probed like a scanned one, yet never listed as an installation.
    @Test func pinsDecideTheirDirectoryAndAnUnusableOneFails() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let pinned = try root.installation("pinned/compiler-17")
        try FileManager.default.createDirectory(at: root.url("workspace/apps"), withIntermediateDirectories: true)
        let missing = root.path + "/pinned/removed"
        let local: [String: Any] = ["version": 1, "toolchains": [:], "pins": [
            ".": ["compiler": ["home": pinned, "version": "17.0.2", "provider": "host:manual"]],
            "apps": ["compiler": ["home": missing, "version": "18", "provider": "host:manual"]]
        ]]
        let probes = DiscoveryProbes(outputs: [pinned + "/bin/compiler": "compiler 17.0.2"])
        let result = await discovery(root: root, probes: probes).discover(.init(
            workspace: root.url("workspace"), sources: [Self.source()], environment: [:],
            local: try JSONSerialization.data(withJSONObject: local)))

        #expect(result.unresolved.isEmpty)
        #expect(result.detections["compiler"]?.installations.isEmpty == true)
        #expect(probes.calls.map(\.executable) == [pinned + "/bin/compiler"])
        #expect(result.resolutions["."]?["compiler"] == .init(layer: .pinned, outcome: .resolved(
            home: pinned, executable: pinned + "/bin/compiler", version: "17.0.2", provider: "host:manual")))
        let failed = try #require(result.resolutions["apps"]?["compiler"])
        #expect(failed.layer == .pinned)
        guard case .failed = failed.outcome else {
            Issue.record("an unusable pin must fail instead of falling through: \(failed.outcome)")
            return
        }
    }

    /// A refused reply names the failure and contributes nothing, not even its valid parts.
    @Test func aRejectedReplyAddsNoInstallationAndIsReported() async throws {
        let root = try DiscoveryFixtureRoot()
        defer { root.remove() }
        let inside = try root.installation("workspace/vendor/compiler")
        let queries = ProviderQueries { _ in
            ["installations": [["tool": "compiler", "version": "1", "home": inside]], "statements": [], "watch": []]
        }
        var discovery = discovery(root: root, probes: DiscoveryProbes(outputs: [:]))
        discovery.queryProvider = { plugin, provider, params, _ in try queries.answer(pluginID: plugin, providerID: provider, params: params) }
        let result = await discovery.discover(.init(
            workspace: root.url("workspace"), sources: [try Self.providerSource()], environment: [:]))
        #expect(result.detections["compiler"]?.installations.isEmpty == true)
        guard case .failed? = result.providerStates[Self.pluginID + ":kits"] else {
            Issue.record("a workspace home must be refused")
            return
        }
        // Without an open context only the global query is sent.
        #expect(queries.sent.count == 1)
        // The refusal is the reported reason; a missing context does not hide it.
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.contains("kits") == true)
    }

    @Test func globsMatchOneComponentLikeCore() {
        #expect(MacToolchainDiscovery.matches("*.kit", "a.kit"))
        #expect(MacToolchainDiscovery.matches("*", "anything"))
        #expect(MacToolchainDiscovery.matches("a*b*c", "aXXbYYc"))
        #expect(MacToolchainDiscovery.matches("kit", "kit"))
        #expect(!MacToolchainDiscovery.matches("*.kit", "a.kit.bak"))
        #expect(!MacToolchainDiscovery.matches("a*b*c", "aXXc"))
        #expect(!MacToolchainDiscovery.matches("kit", "kits"))
    }

    #if DEBUG
    /// The settings preview scans this Mac for real, so its sample manifests must pass Core's admission.
    @MainActor @Test func previewSamplesAreAdmittedByCore() throws {
        let plugins: [[String: Any]] = try ToolchainSettingsDemo.samplePlugins.map { source in
            ["manifest": try JSONSerialization.jsonObject(with: source.manifest), "verifiedOfficial": source.verifiedOfficial]
        }
        let plan = MacToolchainDiscovery.callCore("toolchains.discoveryPlan",
                                                  ["registry": ["plugins": plugins], "platform": "macos"])?["plan"]
        let tools = try #require((plan as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["tool"] as? String }.sorted() == ["java", "maven", "node", "python"])
        #expect(tools.allSatisfy { !($0["scans"] as? [Any] ?? []).isEmpty })
    }
    #endif

    private func discovery(root: DiscoveryFixtureRoot, probes: DiscoveryProbes) -> MacToolchainDiscovery {
        var discovery = MacToolchainDiscovery()
        let home = root.url("home").path
        discovery.homeDirectory = { home }
        discovery.probe = { probes.run($0, $1) }
        return discovery
    }
}

/// A canonical temporary directory with a home and a workspace, removed by the test.
private struct DiscoveryFixtureRoot {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-toolchain-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let resolved = Darwin.realpath(base.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        path = String(cString: resolved)
        try FileManager.default.createDirectory(at: url("home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url("workspace"), withIntermediateDirectories: true)
    }

    func url(_ relative: String) -> URL { URL(fileURLWithPath: path + "/" + relative) }

    /// A home with an executable `bin/compiler`; returns the home path.
    func installation(_ relative: String) throws -> String {
        let executable = url(relative + "/bin/compiler")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return path + "/" + relative
    }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

/// Canned probe outputs keyed by executable; a missing entry is a failed probe.
private final class DiscoveryProbes: @unchecked Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private let outputs: [String: String]
    private var recorded: [Call] = []

    init(outputs: [String: String]) { self.outputs = outputs }

    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ arguments: [String]) -> String? {
        lock.withLock {
            recorded.append(.init(executable: executable, arguments: arguments))
            return outputs[executable]
        }
    }
}

/// A window context whose generation advances on every lookup, as one changing mid-load would.
private final class ContextGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(first: Int) { value = first }

    func next() -> Int {
        lock.withLock { () -> Int in
            defer { value += 1 }
            return value
        }
    }
}

/// Answers queries like a backend would; each result echoes the request's identity.
private final class ProviderQueries: @unchecked Sendable {
    private let lock = NSLock()
    private let result: @Sendable ([String: Any]) -> [String: Any]
    private var recorded: [[String: Any]] = []
    private var nextID = 0

    init(result: @escaping @Sendable ([String: Any]) -> [String: Any]) { self.result = result }

    var sent: [[String: Any]] { lock.withLock { recorded } }

    func answer(pluginID _: String, providerID _: String, params: ToolingJSONValue) throws -> ToolingJSONValue {
        let params = params.foundationObject as? [String: Any] ?? [:]
        let id = lock.withLock { () -> Int in
            recorded.append(params)
            nextID += 1
            return nextID
        }
        var body = result(params)
        for key in ["operationID", "generation", "providerID"] { body[key] = params[key] }
        let reply: [String: Any] = ["id": id, "response": ["jsonrpc": "2.0", "id": id, "result": body]]
        return try #require(ToolingJSONValue.fromFoundation(reply))
    }
}
