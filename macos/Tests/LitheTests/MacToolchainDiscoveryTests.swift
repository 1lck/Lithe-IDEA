import Darwin
import Foundation
import Testing
@testable import Lithe
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
