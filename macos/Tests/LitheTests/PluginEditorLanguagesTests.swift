import Combine
import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI
import Testing

/// Plugin grammars (`languages` 2) apply without a restart; Run marker
/// providers (`runMarkers` 1) come from launch-registered backends. These
/// tests cover which plugins qualify and what the editors receive.
@Suite("Plugin editor languages")
@MainActor
struct PluginEditorLanguagesTests {
    private static let fixtures = DeclarativePluginTestSupport.repositoryRoot
        .appendingPathComponent("shared/contracts/plugins/v1/fixtures", isDirectory: true)

    @Test
    func aGrammarOnlyPluginActivatesWithoutARestart() throws {
        let descriptor = try Self.descriptor("language-grammar")
        #expect(descriptor.languages.map(\.grammarPath) == ["grammars/http.monarch.json"])
        #expect(descriptor.pluginManifest.modules.map(\.manifest.id) == [.grammarsExtension(descriptor.id.rawValue)])
        #expect(descriptor.canActivateWithoutRestart)
    }

    @Test
    func aRunMarkerPluginNeedsARestartForItsBackend() throws {
        let descriptor = try Self.descriptor("run-markers")
        #expect(descriptor.runMarkerProviders == [DeclarativeRunMarkerProvider(
            languageID: "http", functionID: "requests.markers", commandID: "dev.lithe.fixture.httpclient.send"
        )])
        #expect(!descriptor.canActivateWithoutRestart)
    }

    @Test
    func liveGrammarsReachTheEditorAndLeaveWithThePlugin() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package("language-grammar")
        var live = [package]
        let languages = fixture.languages(livePackages: { live })
        let set = languages.current()
        #expect(set.languages.count == 1)
        guard case .object(let language) = try #require(set.languages.first),
              case .object(let grammar) = try #require(language["grammar"]) else {
            Issue.record("decoded language is not an object"); return
        }
        #expect(language["id"] == .string("http"))
        #expect(grammar["kind"] == .string("monarch"))
        #expect(set.runMarkerProviders.isEmpty)
        live = []
        #expect(languages.current() == PluginEditorLanguageSet())
    }

    @Test
    func launchRegisteredGrammarsAndProvidersFollowTheirModules() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package("run-markers")
        let pluginID = package.descriptor.id.rawValue
        var disabled: Set<ModuleID> = []
        let languages = fixture.languages(launchRegistered: [package], isModuleUsable: { !disabled.contains($0) })
        let set = languages.current()
        #expect(set.languages.count == 1)
        #expect(set.runMarkerProviders["http"] == PluginRunMarkerProvider(
            pluginID: pluginID, manifest: package.descriptor.normalizedManifest, languageID: "http",
            functionID: "requests.markers", commandID: "dev.lithe.fixture.httpclient.send"
        ))
        #expect(set.editorPayload["runMarkerLanguages"] as? [String] == ["http"])
        disabled = [ModuleID("\(pluginID).ui")]
        #expect(languages.current().runMarkerProviders.isEmpty)
        #expect(languages.current().languages.count == 1)
        disabled = [.grammarsExtension(pluginID)]
        #expect(languages.current().languages.isEmpty)
    }

    @Test
    func aGrammarOutsideItsPackageOrTooLargeIsRefusedOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package("language-grammar")
        let grammar = package.packageURL.appendingPathComponent("grammars/http.monarch.json")
        try FileManager.default.removeItem(at: grammar)
        let outside = fixture.root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: grammar, withDestinationURL: outside)
        #expect(MacPluginEditorLanguages.packageFile("grammars/http.monarch.json", in: package.packageURL) == nil)
        #expect(MacPluginEditorLanguages.packageFile("../outside.json", in: package.packageURL) == nil)

        var messages: [String] = []
        let languages = fixture.languages(livePackages: { [package] }, log: { message, _ in messages.append(message) })
        #expect(languages.current().languages.isEmpty)
        try FileManager.default.removeItem(at: grammar)
        try Data(repeating: 0x20, count: MacPluginEditorLanguages.maximumGrammarBytes + 1).write(to: grammar)
        #expect(languages.current().languages.isEmpty)
        #expect(languages.current().languages.isEmpty)
        #expect(messages == ["plugin grammar is outside its package", "plugin grammar refused"])
    }

    @Test
    func runMarkerInvocationsCarryTheDocumentOfTheMarker() {
        let invocation = PluginRunMarkerInvocation(id: "request-1", languageID: "http", path: "api/users.http", line: 3, version: 7)
        #expect(invocation.json == .object([
            "id": .string("request-1"), "languageID": .string("http"), "path": .string("api/users.http"),
            "line": .integer(3), "version": .integer(7),
        ]))
        let root = URL(fileURLWithPath: "/workspace")
        #expect(MonacoWorkbenchSession.workspaceRelativePath(of: root.appendingPathComponent("api/users.http"), in: root)
            == "api/users.http")
        #expect(MonacoWorkbenchSession.workspaceRelativePath(of: URL(fileURLWithPath: "/elsewhere/a.http"), in: root) == nil)
        #expect(MonacoWorkbenchSession.workspaceRelativePath(of: root, in: root) == nil)
    }

    private static func descriptor(_ name: String) throws -> DeclarativePluginDescriptor {
        try DeclarativePluginTestSupport.operations.validate(
            manifest: Data(contentsOf: fixtures.appendingPathComponent("\(name).plugin.json"))
        )
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginEditorLanguagesTests-\(UUID().uuidString)", isDirectory: true)

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func package(_ name: String) throws -> InstalledPluginPackage {
            let descriptor = try PluginEditorLanguagesTests.descriptor(name)
            let packageURL = root.appendingPathComponent(name, isDirectory: true)
            let grammars = packageURL.appendingPathComponent("grammars", isDirectory: true)
            try FileManager.default.createDirectory(at: grammars, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: PluginEditorLanguagesTests.fixtures.appendingPathComponent("grammars/http.monarch.json"),
                to: grammars.appendingPathComponent("http.monarch.json")
            )
            return InstalledPluginPackage(
                descriptor: descriptor,
                installation: PluginInstallationRecord(
                    pluginID: descriptor.id, activeVersion: descriptor.pluginManifest.version,
                    origin: .marketplace, status: .installed
                ),
                packageURL: packageURL
            )
        }

        @MainActor
        func languages(
            launchRegistered: [InstalledPluginPackage] = [],
            isModuleUsable: @escaping @MainActor (ModuleID) -> Bool = { _ in true },
            livePackages: @escaping @MainActor () -> [InstalledPluginPackage] = { [] },
            log: @escaping @MainActor (String, [String: String]) -> Void = { _, _ in }
        ) -> MacPluginEditorLanguages {
            MacPluginEditorLanguages(
                launchRegistered: launchRegistered, isModuleUsable: isModuleUsable, livePackages: livePackages,
                decoder: DeclarativePluginTestSupport.operations, triggers: [], log: log
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
