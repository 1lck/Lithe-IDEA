import Foundation
import Testing
@testable import Lithe

@Suite("Localization packaging")
struct LocalizationPackagingTests {
    @Test
    func packagedTablesAreBinaryAndPreserveEveryTranslation() throws {
        let fixture = try LocalizationPackagingFixture()
        defer { fixture.remove() }
        let source = fixture.repository.appendingPathComponent("macos/Resources")
        let destination = fixture.root.appendingPathComponent("Lithe.bundle/Contents/Resources")
        let originalTables = try fixture.tables(in: source)

        // Packaging into an existing directory must remain repeatable without
        // nesting .lproj directories or converting the version-controlled text.
        for _ in 0..<2 {
            let result = fixture.package(source: source, destination: destination)
            try #require(result.succeeded, "\(result.output)")
        }
        let packagedTables = try fixture.tables(in: destination)
        for language in fixture.languages {
            let original = try #require(originalTables[language])
            let packaged = try #require(packagedTables[language])
            #expect(packaged.starts(with: Data("bplist00".utf8)))
            let decoded = try PropertyListSerialization.propertyList(from: packaged, format: nil)
            let expected = try PropertyListSerialization.propertyList(from: original, format: nil)
            #expect(try #require(decoded as? [String: String]) == #require(expected as? [String: String]))
        }
        #expect(try fixture.tables(in: source) == originalTables)

        // Both languages, Unicode and format placeholders must survive the
        // compiled representation, including a return to the first language.
        for language in ["zh-Hans", "en", "zh-Hans"] {
            let bundle = try #require(Bundle(url: destination.appendingPathComponent("\(language).lproj")))
            #expect(bundle.localizedString(forKey: "Terminal", value: nil, table: nil)
                == (language == "en" ? "Terminal" : "终端"))
            let template = bundle.localizedString(forKey: "Conflicts with %@", value: nil, table: nil)
            #expect(String(format: template, "feature/中文-100%")
                == (language == "en" ? "Conflicts with feature/中文-100%" : "与 feature/中文-100% 冲突"))
        }
    }

    @Test
    func invalidOrMissingTablesFailPackaging() throws {
        let fixture = try LocalizationPackagingFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source")
        let destination = fixture.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        #expect(!fixture.package(source: source, destination: destination).succeeded)

        for language in fixture.languages {
            let directory = source.appendingPathComponent("\(language).lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("invalid strings {".utf8).write(to: directory.appendingPathComponent("Localizable.strings"))
        }
        #expect(!fixture.package(source: source, destination: destination).succeeded)
        #expect(!fixture.package(source: source, destination: source).succeeded)
    }
}

private struct LocalizationPackagingFixture {
    let root: URL
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let languages = ["en", "zh-Hans"]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe localization packaging \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove localization fixture: \(error)") }
    }

    func tables(in resources: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: languages.map { language in
            (language, try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings")))
        })
    }

    // Synchronous tests use the existing native runner's bounded process-group
    // cleanup; no main actor or cooperative executor is blocked by the script.
    func package(source: URL, destination: URL) -> ProcessResult {
        MacProcessRunner().run(ProcessRequest(
            executablePath: "/bin/zsh",
            arguments: [repository.appendingPathComponent("scripts/package-macos-localizations.sh").path,
                        source.path, destination.path],
            timeoutMilliseconds: 5_000
        ))
    }
}
