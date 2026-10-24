import Foundation
import Testing
@testable import Lithe

@Suite("Shared built-in translations")
struct SharedI18nTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test
    func languageRegistryPreservesPersistedIdentifiersAndDefault() {
        #expect(AppLanguage.defaultLanguage == .english)
        #expect(AppLanguage(rawValue: "en") == .english)
        #expect(AppLanguage(rawValue: "zh-Hans") == .simplifiedChinese)
        #expect(AppLanguage(rawValue: "unknown") == nil)
        #expect(AppLanguage.english.title == "English")
        #expect(AppLanguage.simplifiedChinese.title == "简体中文")
    }

    @Test(arguments: AppLanguage.allCases)
    func semanticKeysAndLegacyAliasesUseTheSameNativeTable(language: AppLanguage) throws {
        let resources = repository.appendingPathComponent("macos/Resources")
        let bundle = try #require(Bundle(url: resources))
        let chinese = language == .simplifiedChinese
        #expect(language.localizedString("ui.save", bundle: bundle) == (chinese ? "保存" : "Save"))
        #expect(language.localizedString("Save", bundle: bundle) == (chinese ? "保存" : "Save"))
        #expect(language.localizedString("settings.mac.language", bundle: bundle) == (chinese ? "语言" : "Language"))
        #expect(language.localizedString("files.reveal", bundle: bundle) == (chinese ? "在 Finder 中显示" : "Show in Finder"))
        // Legacy and platform-specific wording remains unchanged by migration.
        #expect(language.localizedString("OK", bundle: bundle) == (chinese ? "好" : "OK"))
        #expect(language.localizedString("Terminal", bundle: bundle) == (chinese ? "终端" : "Terminal"))
        #expect(language.localizedString("unknown.fixture", bundle: bundle) == "unknown.fixture")
        for key in ["quickOpen.filesCount", "%lld files"] {
            let format = language.localizedString(key, bundle: bundle)
            for count in [Int64(0), 4, 9_000_000_000] {
                #expect(String(format: format, count) == (chinese ? "\(count) 个文件" : "\(count) files"))
            }
        }
    }

    @Test
    func nativeFormatsHonorSharedReorderingAndLiteralData() throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                let nativeTemplate: String
                let stringValue: String
                let integerValue: Int64
                let expected: String
            }
            let cases: [Case]
        }
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/i18n/format-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        for item in fixture.cases {
            #expect(String(format: item.nativeTemplate, item.stringValue, item.integerValue) == item.expected)
        }
    }

    @Test
    func nativeABIFormatsPreserveTheWholeUnsignedRange() throws {
        struct Fixture: Decodable {
            let nativeTemplate: String
            let unsignedValue: String
            let integerValue: Int32
            let expected: String
        }
        let data = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/i18n/native-abi-v1.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let rows = try #require(UInt64(fixture.unsignedValue))
        #expect(String(format: fixture.nativeTemplate, rows, fixture.integerValue) == fixture.expected)
    }

    @Test
    func switchingLanguageReadsResourcesWithoutChangingTheirBytes() throws {
        let resources = repository.appendingPathComponent("macos/Resources")
        let tables = AppLanguage.allCases.map {
            resources.appendingPathComponent("\($0.rawValue).lproj/Localizable.strings")
        }
        let before = try tables.map { try Data(contentsOf: $0) }
        let bundle = try #require(Bundle(url: resources))
        for language in [AppLanguage.english, .simplifiedChinese, .english] {
            #expect(language.localizedString("ui.cancel", bundle: bundle) == (language == .english ? "Cancel" : "取消"))
        }
        #expect(try tables.map { try Data(contentsOf: $0) } == before)
    }
}
