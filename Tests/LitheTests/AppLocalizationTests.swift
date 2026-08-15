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
        #expect(translations["Authorize in your browser"] == "在浏览器中授权")
        #expect(translations["Select a pull request"] == "选择一个拉取请求")
        #expect(translations["Request changes"] == "请求修改")
        #expect(translations["Create Pull Request"] == "创建拉取请求")
        #expect(translations["Comparing changes"] == "比较更改")
        #expect(translations["Ready to create"] == "可以创建拉取请求")
        #expect(translations["Select branch"] == "选择分支")
        #expect(translations["Search branches"] == "搜索分支")
        #expect(translations["Generate with AI"] == "AI 生成")
        #expect(translations["Pull request description generation"] == "拉取请求描述生成")
        #expect(translations["Custom template"] == "自定义模板")
        #expect(translations["Publish this worktree"] == "发布当前工作树")
        #expect(translations["Publish Branch"] == "发布分支")
        #expect(
            translations["Uncommitted changes stay in this worktree and are not included in the pull request."]
                == "未提交的更改会保留在当前工作树中，不会包含在拉取请求里。"
        )
        #expect(
            translations["The selected branch diff is sent to the active AI provider when you generate."]
                == "生成时，所选分支的差异内容会发送给当前 AI 服务商。"
        )
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
