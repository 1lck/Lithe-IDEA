import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
@testable import Lithe
import Testing

struct MacExtensionHostResourcesTests {
    @Test func resolvesManagedResourcesAndPartitionsWorkspaceStorage() throws {
        let fixture = try ResourcesFixture()
        defer { fixture.remove() }
        let resources = MacExtensionHostResources(resourceRoot: fixture.bundle,
            storageRoot: fixture.storage, architecture: "fixture")
        let first = try resources.startup(workspace: fixture.workspace, environment: [:])
        #expect(first.launch.node == fixture.bundle.appendingPathComponent("node").resolvingSymlinksInPath())
        guard case .object(let initial) = first.initialize else { Issue.record("Invalid initialization"); return }
        #expect(first.launch.environment["PATH"] == first.launch.node.deletingLastPathComponent().path)
        #expect(initial["workspaceTrusted"] == .bool(false))
        let again = try resources.startup(workspace: fixture.workspace, environment: [:])
        #expect(again.initialize == first.initialize)
        let secondWorkspace = fixture.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondWorkspace, withIntermediateDirectories: true)
        let second = try resources.startup(workspace: secondWorkspace, environment: [:])
        guard case .object(let other) = second.initialize,
              case .object(let firstStorage)? = initial["storage"],
              case .object(let secondStorage)? = other["storage"] else {
            Issue.record("Missing storage configuration"); return
        }
        #expect(firstStorage["globalStoragePath"] == secondStorage["globalStoragePath"])
        #expect(firstStorage["workspaceStoragePath"] != secondStorage["workspaceStoragePath"])
    }

    @Test(arguments: ["../node", "/node", "nested/../node", "node\\escape"])
    func rejectsNonBundlePaths(nodePath: String) throws {
        let fixture = try ResourcesFixture()
        defer { fixture.remove() }
        try fixture.writeManifest(nodePath: nodePath)
        let resources = MacExtensionHostResources(resourceRoot: fixture.bundle,
            storageRoot: fixture.storage, architecture: "fixture")
        #expect(throws: ExtensionHostFailure.self) {
            try resources.startup(workspace: fixture.workspace, environment: [:])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.storage.path))
    }

    @Test func rejectsEscapingSymlinkAndMissingArchitecture() throws {
        let fixture = try ResourcesFixture()
        defer { fixture.remove() }
        let external = fixture.root.appendingPathComponent("external-node")
        try Data().write(to: external)
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("node"))
        try FileManager.default.createSymbolicLink(at: fixture.bundle.appendingPathComponent("node"), withDestinationURL: external)
        for architecture in ["fixture", "missing"] {
            let resources = MacExtensionHostResources(resourceRoot: fixture.bundle,
                storageRoot: fixture.storage, architecture: architecture)
            #expect(throws: ExtensionHostFailure.self) {
                try resources.startup(workspace: fixture.workspace, environment: [:])
            }
        }
    }
}

private struct ResourcesFixture {
    let root: URL
    let bundle: URL
    let storage: URL
    let workspace: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        bundle = root.appendingPathComponent("bundle", isDirectory: true)
        storage = root.appendingPathComponent("storage", isDirectory: true)
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        do {
            for directory in [workspace, bundle.appendingPathComponent("extensions/probe", isDirectory: true)] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for name in ["node", "main.js", "extensions/probe/package.json"] {
                try Data().write(to: bundle.appendingPathComponent(name))
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("node").path)
            try writeManifest(nodePath: "node")
        } catch {
            remove()
            throw error
        }
    }

    func writeManifest(nodePath: String) throws {
        let json: [String: Any] = ["schemaVersion": 1, "nodePaths": ["fixture": nodePath],
            "entrypoint": "main.js", "extensionPaths": ["extensions/probe"]]
        try JSONSerialization.data(withJSONObject: json).write(to: bundle.appendingPathComponent("manifest.json"))
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record(error) }
    }
}
