import Foundation
import Testing
@testable import Lithe

@Suite("App localization")
@MainActor
struct AppLocalizationTests {
    @Test
    func languageDefaultsToEnglishAndPersistsChanges() {
        let store = LocalizationTestKeyValueStore()
        let settings = AppSettings(store: store)

        #expect(settings.language == .english)
        #expect(settings.language.locale.identifier == "en")

        settings.language = .simplifiedChinese
        let reloadedSettings = AppSettings(store: store)

        #expect(reloadedSettings.language == .simplifiedChinese)
        #expect(reloadedSettings.language.locale.identifier == "zh-Hans")

        reloadedSettings.restoreDefaults()
        #expect(AppSettings(store: store).language == .english)
    }

    @Test
    func simplifiedChineseResourcesCoverSettingsLanguageControls() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Settings"] == "设置")
        #expect(translations["General"] == "通用")
        #expect(translations["Language"] == "语言")
        #expect(translations["English"] == "英文")
        #expect(
            translations["The interface language changes immediately. English is the default."]
                == "界面语言会立即生效。默认语言为英文。"
        )
    }

    @Test
    func simplifiedChineseResourcesCoverGitHubPullRequests() throws {
        let translations = try simplifiedChineseTranslations()

        #expect(translations["Pull Requests"] == "拉取请求")
        #expect(translations["Sign in to GitHub"] == "登录 GitHub")
        #expect(translations["Use an access token"] == "使用访问令牌")
        #expect(translations["Select a pull request"] == "选择一个拉取请求")
        #expect(translations["Request changes"] == "请求修改")
        #expect(translations["Create Pull Request"] == "创建拉取请求")
    }

    private func simplifiedChineseTranslations() throws -> [String: String] {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceURL = repositoryRoot
            .appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let data = try Data(contentsOf: resourceURL)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        return try #require(propertyList as? [String: String])
    }
}

private final class LocalizationTestKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
