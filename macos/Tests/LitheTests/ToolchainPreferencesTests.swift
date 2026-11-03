import Foundation
import AppKit
import SwiftUI
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Toolchain preference editing", .serialized)
@MainActor
struct ToolchainPreferencesTests {
    private let address = ToolchainPreferenceAddress(directory: ".", consumer: nil, tool: "dev.example.runtime:sdk")

    @Test
    func openDraftCancelAndEmptyResetDoNotCreateFiles() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store()
        let model = ToolchainPreferencesFeatureModel(store: store)
        defer { model.close() }
        await model.open(workspace: root, address: address)
        #expect(model.error == nil && model.draft?.mode == .inherited)
        model.edit(mode: .installation, path: "/fixture/draft-sdk")
        #expect(model.draft?.isChanged == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe").path))
        model.hide(address)
        await model.open(workspace: root, address: address)
        #expect(model.draft?.path == "/fixture/draft-sdk" && model.draft?.isChanged == true)
        await model.cancel()
        await model.save(reset: true)
        #expect(model.error == nil && model.draft?.isChanged == false)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe").path))
    }

    @Test(arguments: [false, true])
    func nativeSaveAndResetButtonsUseTheGuardedStore(dark: Bool) async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = store()
        let model = ToolchainPreferencesFeatureModel(store: native)
        let tool = ToolchainSettingsSnapshot.Tool(id: address.tool, displayName: "Fixture SDK", pluginID: "dev.example.runtime",
            pluginName: "Fixture runtime", consumers: [.init(id: "dev.example.build/engine", title: "Fixture Build", pluginName: "Fixture provider")])
        let application = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = application.accessibilityAttributeValue(attribute)
        application.accessibilitySetValue(true, forAttribute: attribute)
        let host = NSHostingView(rootView: ToolchainPreferenceEditorView(editor: model, workspace: root, tool: tool)
            .padding(16).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {
            model.close(); window.contentView = nil; window.orderOut(nil); window.close()
            application.accessibilitySetValue(previous, forAttribute: attribute)
        }
        let open = try await control("toolchain-preference-open:" + tool.id, in: host)
        #expect(open.accessibilityPerformPress?() == true)
        try await settled(in: host, stage: "opening draft") { model.draft != nil && !model.isLoading }
        model.edit(mode: .installation, path: "/fixture/saved-sdk")
        let save = try await control("toolchain-preference-save:" + tool.id, in: host)
        try await settled(in: host, stage: "enabling Save") { save.isAccessibilityEnabled?() == true }
        #expect(save.accessibilityPerformPress?() == true)
        try await settled(in: host, stage: "saving draft") { model.draft?.isChanged == false && !model.isSaving }
        #expect(model.error == nil)
        let saved = try await native.load(workspace: root)
        #expect(try native.inspect(address, snapshot: saved).fixed == .installation(home: "/fixture/saved-sdk"))
        let reset = try await control("toolchain-preference-reset:" + tool.id, in: host)
        #expect(reset.accessibilityPerformPress?() == true)
        try await settled(in: host, stage: "resetting selection") { model.draft?.mode == .inherited && !model.isSaving }
        #expect(model.error == nil)
        let resetSnapshot = try await native.load(workspace: root)
        #expect(try native.inspect(address, snapshot: resetSnapshot).stored == nil)
    }

    @Test
    func explicitSaveReopensPreservesOtherRunFieldsAndFilePermissions() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent(".lithe/run/local.json")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = ["version": 2, "configurations": [], "future": ["keep": true],
            "toolchain": ["java": ["homePath": "/fixture/legacy-jdk"], "future": "keep"]]
        try JSONSerialization.data(withJSONObject: original).write(to: local)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: local.path)
        let store = store()
        let initial = try await store.load(workspace: root)
        let saved = try await store.save(.object(["home": .string("/fixture/chosen-sdk")]), at: address, expecting: initial)
        #expect(try store.inspect(address, snapshot: saved).fixed == .installation(home: "/fixture/chosen-sdk"))
        #expect(try await store.load(workspace: root) == saved)
        let data = try Data(contentsOf: local)
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var toolchain = try #require(document["toolchain"] as? [String: Any])
        toolchain.removeValue(forKey: "preferences"); document["toolchain"] = toolchain
        #expect(NSDictionary(dictionary: document).isEqual(to: original))
        #expect((try FileManager.default.attributesOfItem(atPath: local.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(try String(contentsOf: root.appendingPathComponent(".lithe/.gitignore"), encoding: .utf8).contains("run/local.json"))
    }

    @Test
    func consumerToolReferenceSurvivesNativeSaveReopenAndDirectoryDefaultChanges() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = store()
        let directory = ToolchainPreferenceAddress(directory: "nested", consumer: nil, tool: address.tool)
        let consumer = ToolchainPreferenceAddress(directory: ".", consumer: "dev.example.build/engine", tool: address.tool)
        let child = ToolchainPreferenceAddress(directory: "nested/child", consumer: consumer.consumer, tool: address.tool)
        var baseline = try await native.load(workspace: root)
        baseline = try await native.save(.object(["home": .string("/fixture/workspace-sdk")]), at: address, expecting: baseline)
        baseline = try await native.save(.object(["home": .string("/fixture/directory-sdk")]), at: directory, expecting: baseline)
        _ = try await native.save(.object(["inherit": .string("tool")]), at: consumer, expecting: baseline)
        let model = ToolchainPreferencesFeatureModel(store: native)
        defer { model.close() }
        await model.open(workspace: root, address: child)
        #expect(model.reading?.fixed == .installation(home: "/fixture/directory-sdk"))
        model.edit(mode: .directoryTool)
        await model.save()
        #expect(model.error == nil && model.reading?.stored == .object(["inherit": .string("tool")]))
        model.close()
        await model.open(workspace: root, address: child)
        #expect(model.draft?.mode == .directoryTool && model.reading?.fixed == .installation(home: "/fixture/directory-sdk"))
        baseline = try await native.load(workspace: root)
        _ = try await native.save(.object(["home": .string("/fixture/changed-sdk")]), at: directory, expecting: baseline)
        await model.open(workspace: root, address: child)
        #expect(model.error == nil && model.draft?.mode == .directoryTool)
        #expect(model.reading?.fixed == .installation(home: "/fixture/changed-sdk"))
        #expect(model.reading?.stored == .object(["inherit": .string("tool")]))
    }

    @Test
    func externalEditKeepsTheOriginalDraftBaselineUntilExplicitCancel() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store()
        let model = ToolchainPreferencesFeatureModel(store: store)
        defer { model.close() }
        await model.open(workspace: root, address: address)
        model.edit(mode: .executable, path: "/fixture/draft/compiler")
        let initial = try await store.load(workspace: root)
        _ = try await store.save(.object(["home": .string("/fixture/external-sdk")]), at: address, expecting: initial)
        let local = root.appendingPathComponent(".lithe/run/local.json")
        let external = try Data(contentsOf: local)
        await model.open(workspace: root, address: address)
        #expect(model.error != nil && model.draft?.path == "/fixture/draft/compiler")
        await model.save()
        #expect(model.error != nil && model.draft?.isChanged == true)
        #expect(try Data(contentsOf: local) == external)
        await model.cancel()
        #expect(model.error == nil && model.draft?.path == "/fixture/external-sdk")
        model.edit(mode: .installation, path: "/fixture/retained-draft")
        try Data("{broken".utf8).write(to: local)
        await model.open(workspace: root, address: address)
        #expect(model.error != nil && model.draft?.path == "/fixture/retained-draft")
    }

    @Test
    func preferencesOnlyDocumentDoesNotSuppressLegacyDefaultMigration() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store()
        let initial = try await store.load(workspace: root)
        let saved = try await store.save(.object(["home": .string("/fixture/generic-sdk")]), at: address, expecting: initial)
        let preferences = PreferenceMigrationValues()
        preferences.set(try JSONEncoder().encode(ProjectRuntimeSettings(javaHomePath: "/fixture/old-jdk")),
                        forKey: MacProjectRuntimeSettingsStore.preferencesKey(root))
        let runtime = MacProjectRuntimeSettingsStore(core: RustCoreBridge(), storage: MacFileStorage(), preferences: preferences)
        let migrated = try runtime.load(at: root, migrateLegacy: true)
        #expect(migrated.settings.javaHomePath == "/fixture/old-jdk")
        let after = try await store.load(workspace: root)
        #expect(after.document == saved.document)
        #expect(try store.inspect(address, snapshot: after).fixed == .installation(home: "/fixture/generic-sdk"))
    }

    @Test(arguments: ["immutable", "parent-alias", "file-alias", "invalid"])
    func invalidOrReadOnlyTargetsRemainUnchanged(kind: String) async throws {
        let root = try workspace(), outside = try workspace()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let local = root.appendingPathComponent(".lithe/run/local.json")
        let source = outside.appendingPathComponent("local.json")
        let bytes = Data("{\"version\":2,\"configurations\":[]}".utf8)
        try bytes.write(to: source)
        if kind == "parent-alias" {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".lithe"), withDestinationURL: outside)
        } else if kind == "file-alias" || kind == "invalid" {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            if kind == "file-alias" { try FileManager.default.createSymbolicLink(at: local, withDestinationURL: source) }
            else { try Data("{broken".utf8).write(to: local) }
        }
        let store = store(immutable: kind == "immutable" ? [root] : [])
        await #expect(throws: (any Error).self) { try await store.load(workspace: root) }
        #expect(try Data(contentsOf: source) == bytes)
        if kind == "invalid" { #expect(try Data(contentsOf: local) == Data("{broken".utf8)) }
    }

    @Test
    func cancelledSaveAndWorkspaceCloseDrainWithoutPublishingOrWriting() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let native = store()
        let initial = try await native.load(workspace: root)
        let cancelled = Task { try await native.save(.object(["home": .string("/fixture/sdk")]), at: address, expecting: initial) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".lithe").path))

        let controlled = PreferenceEditorStore(snapshot: initial)
        let model = ToolchainPreferencesFeatureModel(store: controlled)
        defer { controlled.beforeSave = nil; model.close() }
        await model.open(workspace: root, address: address)
        model.edit(mode: .installation, path: "/fixture/sdk")
        controlled.beforeSave = { model.close() }
        await model.save()
        await model.drain()
        #expect(controlled.saveAttempts == 1 && controlled.completedWrites == 0)
        #expect(model.workspace == nil && model.draft == nil && !model.isSaving)
        controlled.beforeSave = nil
        await model.open(workspace: root, address: address)
        #expect(model.draft?.mode == .inherited && model.error == nil)
    }

    private func store(immutable: [URL] = []) -> MacToolchainPreferencesStore {
        .init(core: RustCoreBridge(), storage: MacFileStorage(), immutableRoots: { immutable })
    }
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-preference-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func control(_ id: String, in view: NSView) async throws -> AnyObject {
        func elements(_ item: Any, depth: Int = 0) -> [AnyObject] {
            guard depth < 48 else { return [] }
            let object = item as AnyObject
            let children = object.accessibilityChildren?() ?? []
            let descendants: [Any] = children.isEmpty ? ((item as? NSView)?.subviews ?? []) : children
            return [object] + descendants.flatMap { elements($0, depth: depth + 1) }
        }
        var found: AnyObject?
        try await settled(in: view, stage: "finding " + id) { found = elements(view).first { $0.accessibilityIdentifier?() == id }; return found != nil }
        return try #require(found)
    }

    /// SwiftUI has no accessibility publication callback; observe the product
    /// control/state with a local monotonic deadline and close the host in defer.
    private func settled(in view: NSView, stage: String, until predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            view.layoutSubtreeIfNeeded()
            if predicate() { return }
            await Task.yield()
        } while clock.now < deadline
        Issue.record("Toolchain preference control did not settle within two seconds: \(stage)")
        throw ToolchainPreferenceError.invalid
    }
}

@MainActor
private final class PreferenceEditorStore: ToolchainPreferencesStoring {
    let snapshot: ToolchainPreferencesSnapshot
    var beforeSave: (() -> Void)?
    var saveAttempts = 0, completedWrites = 0
    init(snapshot: ToolchainPreferencesSnapshot) { self.snapshot = snapshot }
    func load(workspace: URL) async throws -> ToolchainPreferencesSnapshot { snapshot }
    func inspect(_ address: ToolchainPreferenceAddress, snapshot: ToolchainPreferencesSnapshot) throws -> ToolchainPreferenceReading {
        .init(stored: nil, fixed: nil, source: "automatic")
    }
    func save(_ value: ToolingJSONValue?, at address: ToolchainPreferenceAddress,
              expecting snapshot: ToolchainPreferencesSnapshot) async throws -> ToolchainPreferencesSnapshot {
        saveAttempts += 1; beforeSave?()
        try Task.checkCancellation()
        completedWrites += 1
        return snapshot
    }
}

private final class PreferenceMigrationValues: KeyValueStore {
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
