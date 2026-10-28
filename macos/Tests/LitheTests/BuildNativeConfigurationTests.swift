import CryptoKit
import AppKit
import Darwin
import Foundation
import LitheCoreContracts
import LitheModuleAPI
import Testing
import SwiftUI
@testable import Lithe

@Suite("Native build configuration files and drafts")
struct BuildNativeConfigurationTests {
    @Test
    func inheritedValuesPopulateWithoutCreatingOverridesAndCancelRestoresBaseline() throws {
        let fixture = try NativeConfigurationFixture()
        defer { fixture.cleanup() }
        let snapshot = try fixture.snapshot()
        let source = try #require(snapshot.sources.first)
        let field = try #require(source.fields.first)
        var draft = BuildNativeConfigurationDraft(source: source)
        #expect(draft.text(field.id) == "/inherited/repository")
        #expect(!draft.isDirty)
        draft.setOverride(true, fieldID: field.id)
        #expect(draft.edits.values[field.id] == .string("/inherited/repository"))
        draft.setText("/edited/repository", field: field)
        #expect(draft.isDirty)
        draft = BuildNativeConfigurationDraft(source: source)
        #expect(!draft.isDirty)
        #expect(try fixture.text() == fixture.original)
    }

    @Test
    func savePreservesSecretsCommentsModeAndExtendedAttributes() throws {
        let fixture = try NativeConfigurationFixture()
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.file.path)
        let attribute = "com.lithe.fixture"
        let marker = Data("retained".utf8)
        let set = marker.withUnsafeBytes { bytes in
            setxattr(fixture.file.path, attribute, bytes.baseAddress, bytes.count, 0, 0)
        }
        try #require(set == 0)
        let snapshot = try fixture.snapshot()
        let write = try #require(try fixture.store().prepare(target: fixture.target, snapshot: snapshot, edits: fixture.edits(snapshot)))
        #expect(try fixture.text() == fixture.original)
        try fixture.store().commit(write)
        let text = try fixture.text()
        #expect(text.contains("<localRepository>/new/repository</localRepository>"))
        #expect(text.contains("<!-- keep comment -->"))
        #expect(text.contains("<password>test-secret-preserved</password>"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = getxattr(fixture.file.path, attribute, &buffer, buffer.count, 0, 0)
        #expect(count == marker.count)
        #expect(Data(buffer.prefix(max(0, count))) == marker)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["settings.xml"])
    }

    @Test
    func externalEditsBeforePreparationAndInsideAtomicPublishAreRetained() throws {
        let fixture = try NativeConfigurationFixture()
        defer { fixture.cleanup() }
        let snapshot = try fixture.snapshot()
        try Data("external".utf8).write(to: fixture.file)
        #expect(throws: (any Error).self) {
            try fixture.store().prepare(target: fixture.target, snapshot: snapshot, edits: fixture.edits(snapshot))
        }
        #expect(try fixture.text() == "external")
        try Data(fixture.original.utf8).write(to: fixture.file)
        let write = try #require(try fixture.store().prepare(target: fixture.target, snapshot: snapshot, edits: fixture.edits(snapshot)))
        var storage = MacFileStorage()
        let file = fixture.file
        storage.afterPreparingTemporaryForTesting = { try? Data("external in exchange".utf8).write(to: file) }
        #expect(throws: (any Error).self) { try fixture.store(storage: storage).commit(write) }
        #expect(try fixture.text() == "external in exchange")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path) == ["settings.xml"])
    }

    @Test
    func missingFileStaysMissingOnNoOpAndExplicitSaveCreatesPrivateFile() throws {
        let fixture = try NativeConfigurationFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.file)
        let snapshot = try fixture.snapshot()
        #expect(try fixture.store().prepare(target: fixture.target, snapshot: snapshot,
            edits: BuildNativeConfigurationEdits(sourceID: "user", revision: "missing", values: [:])) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        let write = try #require(try fixture.store().prepare(target: fixture.target, snapshot: snapshot, edits: fixture.edits(snapshot)))
        try fixture.store().commit(write)
        #expect(try fixture.text().contains("<localRepository>/new/repository</localRepository>"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func packageRootsAndChangedSymlinkTargetsAreRejected() throws {
        let fixture = try NativeConfigurationFixture()
        defer { fixture.cleanup() }
        let snapshot = try fixture.snapshot()
        #expect(throws: (any Error).self) {
            try fixture.store(immutableRoots: [fixture.root]).prepare(target: fixture.target, snapshot: snapshot, edits: fixture.edits(snapshot))
        }
        let link = fixture.root.appendingPathComponent("selected.xml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        let linked = try fixture.snapshot(sourceURL: link)
        let write = try #require(try fixture.store().prepare(target: fixture.target, snapshot: linked, edits: fixture.edits(linked)))
        try FileManager.default.removeItem(at: link)
        let other = fixture.root.appendingPathComponent("other.xml")
        try Data(fixture.original.utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(throws: (any Error).self) { try fixture.store().commit(write) }
        #expect(try fixture.text() == fixture.original)
        #expect(try String(contentsOf: other, encoding: .utf8) == fixture.original)
    }
}

@Suite("Native configuration settings controls", .serialized)
@MainActor
struct NativeConfigurationSettingsControlTests {
    @Test(arguments: [600.0, 900.0], [false, true])
    func inheritedValueIsVisibleAndChoosingThenSavingRequiresAnExplicitOverride(width: Double, dark: Bool) async throws {
        let fixture = try NativeConfigurationFixture()
        defer { fixture.cleanup() }
        let source = try #require(try fixture.snapshot().sources.first)
        var picked = false
        var saved: BuildNativeConfigurationEdits?
        let selected = URL(fileURLWithPath: "/fixture/chosen repository")
        let editor = NativeBuildConfigurationSourceEditor(source: source, busy: false, stale: false,
            choosePath: { directory in picked = directory; return selected }, save: { saved = $0 })
            .padding(14).frame(width: width, height: 290, alignment: .topLeading)
            .background(LitheTheme.settingsSurface)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 290),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        let application = NSApplication.shared
        let accessibilityAttribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = (application.accessibilityAttributeValue(accessibilityAttribute) as? Bool) ?? false
        application.accessibilitySetValue(true, forAttribute: accessibilityAttribute)
        defer { application.accessibilitySetValue(previous, forAttribute: accessibilityAttribute) }
        let override = try #require(await element(in: host, role: .checkBox, label: L10n.string("Override")))
        let save = try #require(await element(in: host, role: .button, label: L10n.string("Save")))
        #expect(save.isAccessibilityEnabled?() == false)
        #expect(descendants(host).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "/inherited/repository" })
        #expect(override.accessibilityPerformPress?() == true)
        let choose = try #require(await element(in: host, role: .button, label: L10n.string("Choose"), enabled: true))
        #expect(choose.accessibilityPerformPress?() == true)
        #expect(picked)
        let enabledSave = try #require(await element(in: host, role: .button, label: L10n.string("Save"), enabled: true))
        #expect(enabledSave.accessibilityPerformPress?() == true)
        #expect(saved?.values["localRepository"] == .string(selected.path))
        #expect(try fixture.text() == fixture.original)
        let field = try #require(descendants(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == selected.path })
        #expect(host.bounds.contains(field.convert(field.bounds, to: host)))
        if let directory = ProcessInfo.processInfo.environment["LITHE_NATIVE_CONFIGURATION_CAPTURES"] {
            let bitmap = try nativeSRGBCapture(host)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("native-configuration-\(Int(width))-\(dark ? "dark" : "light").png"))
        }
        let cancel = try #require(await element(in: host, role: .button, label: L10n.string("Cancel"), enabled: true))
        #expect(cancel.accessibilityPerformPress?() == true)
        #expect(await element(in: host, role: .button, label: L10n.string("Save"), enabled: false) != nil)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func element(in host: NSView, role: NSAccessibility.Role, label: String, enabled: Bool? = nil) async -> AnyObject? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            host.layoutSubtreeIfNeeded()
            for element in accessibleElements(host) {
                guard element.accessibilityRole?() == role else { continue }
                let title = element.accessibilityLabel?() ?? element.accessibilityTitle?()
                guard title == label else { continue }
                if let enabled, element.isAccessibilityEnabled?() != enabled { continue }
                return element
            }
            await Task.yield()
        } while clock.now < deadline
        return nil
    }
    private func accessibleElements(_ element: Any) -> [AnyObject] {
        let accessible = element as AnyObject
        let children = accessible.accessibilityChildren?() ?? []
        let descendants: [Any] = children.isEmpty ? ((element as? NSView)?.subviews ?? []) : children
        return [accessible] + descendants.flatMap(accessibleElements)
    }
}

private struct NativeConfigurationFixture {
    let root: URL
    let file: URL
    let target: BuildSystemTarget
    let planner = RustBuildSystemOperations(core: RustCoreBridge())
    let original = """
    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"><!-- keep comment -->
    <servers><server><password>test-secret-preserved</password></server></servers></settings>
    """
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lithe-native-settings-\(UUID().uuidString)")
        file = root.appendingPathComponent("settings.xml")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest = try Data(contentsOf: DeclarativePluginTestSupport.repositoryRoot.appendingPathComponent(
            "shared/contracts/plugins/v1/fixtures/build-provider-configuration.plugin.json"))
        target = BuildSystemTarget(manifest: manifest, buildSystemID: "gradle")
        try Data(original.utf8).write(to: file)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func text() throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func store(storage: MacFileStorage = MacFileStorage(), immutableRoots: [URL] = []) -> MacBuildNativeConfigurationStore {
        MacBuildNativeConfigurationStore(storage: storage, planner: planner, immutableRoots: immutableRoots)
    }
    func snapshot(sourceURL: URL? = nil) throws -> BuildNativeConfiguration {
        let data = try? Data(contentsOf: file)
        let revision = data.map { "sha256:" + SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "missing"
        let value: [String: Any] = ["format": "litheBuildConfiguration", "version": 1, "sources": [[
            "id": "user", "scope": "user", "uri": (sourceURL ?? file).absoluteString, "revision": revision, "writable": true,
            "rootElement": ["name": "settings", "namespace": "http://maven.apache.org/SETTINGS/1.0.0"],
            "fields": [["id": "localRepository", "kind": "directory", "value": NSNull(),
                "effectiveValue": "/inherited/repository", "effectiveSource": "default", "path": ["localRepository"]]]
        ]]]
        let wire = try JSONDecoder().decode(ToolingJSONValue.self, from: JSONSerialization.data(withJSONObject: value))
        return try planner.decodeConfiguration(target, result: wire)
    }
    func edits(_ snapshot: BuildNativeConfiguration) -> BuildNativeConfigurationEdits {
        BuildNativeConfigurationEdits(sourceID: "user", revision: snapshot.sources[0].revision,
            values: ["localRepository": .string("/new/repository")])
    }
}
