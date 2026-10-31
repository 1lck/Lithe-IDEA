import Combine
import Foundation
@testable import Lithe
import LitheCoreContracts
import LitheModuleAPI
import LitheApplicationKernel
import Testing

/// Static editor resources are accepted without language-server or Run providers.
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
    func grammarContributionsPassTheRealCatalogValidation() throws {
        let descriptor = try Self.descriptor("language-grammar")
        let catalog = try ValidatedPluginCatalog(manifests: BuiltInPluginCatalog.manifests + [descriptor.pluginManifest],
                                                 hostVersion: BuiltInPluginCatalog.hostVersion)
        #expect(catalog.languageSupport(for: URL(fileURLWithPath: "/workspace/test.http")) != nil)
        #expect(descriptor.pluginManifest.languageSupports?.first?.isEditorOnly == true)
        #expect(descriptor.pluginManifest.languageSupports?.languageIDs(requiringExtensionFor: .run).isEmpty == true)
    }

    @Test
    func aStandaloneToolBackendPassesTheCatalogWithoutFakeUIOrLSP() throws {
        let descriptor = try Self.descriptor("editor-actions")
        #expect(descriptor.pluginManifest.modules.map(\.manifest.id) == [.backendExtension(descriptor.id.rawValue)])
        #expect(descriptor.languages.isEmpty)
        #expect(descriptor.languageServers.isEmpty)
        _ = try ValidatedPluginCatalog(manifests: BuiltInPluginCatalog.manifests + [descriptor.pluginManifest],
                                       hostVersion: BuiltInPluginCatalog.hostVersion)
    }

    @Test
    func configurationOnlyNeedsNoBackendAndDecodesWithoutAFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            Self.fixtures.appendingPathComponent("language-grammar.plugin.json"))) as? [String: Any])
        var languages = try #require(object["languages"] as? [[String: Any]])
        languages[0]["grammar"] = nil
        object["languages"] = languages
        let descriptor = try DeclarativePluginTestSupport.operations.validate(manifest: JSONSerialization.data(withJSONObject: object))
        #expect(!descriptor.declaresBackend)
        #expect(descriptor.canActivateWithoutRestart)
        let decoded = try DeclarativePluginTestSupport.operations.decodeGrammar(manifest: descriptor.normalizedManifest,
                                                                               languageID: "http", grammar: "")
        guard case .object(let result) = decoded, case .object(let configuration)? = result["configuration"] else {
            Issue.record("missing independent editor configuration"); return
        }
        #expect(result["grammar"] == .null)
        #expect(configuration["lineComment"] == .string("#"))
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
        live = []
        #expect(languages.current() == PluginEditorLanguageSet())
    }

    @Test
    func staticEditorResourcesFollowTheirOwnEnablement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let package = try fixture.package("language-grammar")
        var enabled = true
        let languages = fixture.languages(launchRegistered: [package], isModuleUsable: { _ in enabled })
        #expect(languages.current().languages.count == 1)
        enabled = false
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
