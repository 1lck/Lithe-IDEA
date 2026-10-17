import Foundation
import Testing
@testable import Lithe

@MainActor
struct LanguageTestLocalizationTests {
    private func localization(_ language: AppLanguage) throws -> LanguageTestLocalization {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        return LanguageTestLocalization(language: language, resourceBundle: try #require(Bundle(url: resources)))
    }

    @Test
    func testResultsFollowTheSelectedAppLanguage() throws {
        let chinese = try localization(.simplifiedChinese)
        let english = try localization(.english)
        for (key, value) in ["Results": "测试结果", "Failures": "失败详情",
                             "Passed": "通过", "Failed": "失败", "Skipped": "跳过",
                             "Timed Out": "已超时", "Cancelled": "已取消",
                             "Rerun last test": "重新运行上次测试"] {
            #expect(chinese.text(key) == value)
            #expect(english.text(key) == key)
        }
        #expect(chinese.count("Passed", 12) == "通过 12")
        #expect(english.count("Skipped", 0) == "Skipped 0")
    }

    @Test func summaryUsesIDEAWordOrderAndLocalizedPluralForms() throws {
        let chinese = try localization(.simplifiedChinese)
        let english = try localization(.english)
        #expect(english.number("%lld test failed", 1) == "1 test failed")
        #expect(english.number("%lld tests failed", 2) == "2 tests failed")
        #expect(english.number("%lld passed", 3) == "3 passed")
        #expect(english.number("%lld ignored", 1) == "1 ignored")
        #expect(english.number("%lld tests total", 6) == "6 tests total")
        #expect(chinese.number("%lld tests failed", 2) == "2 个测试失败")
        #expect(chinese.number("%lld passed", 3) == "3 个通过")
        #expect(chinese.number("%lld ignored", 1) == "1 个已忽略")
        #expect(chinese.number("%lld tests total", 6) == "共 6 个测试")
        #expect(chinese.text(", ") == "，")
    }

    @Test
    func testTimeoutPreservesFrameworkAndDurationAndUnknownDiagnostics() throws {
        let chinese = try localization(.simplifiedChinese)
        let english = try localization(.english)
        for framework in ["Maven", "JUnit"] {
            let message = framework + " test run timed out after 120 seconds."
            #expect(chinese.error(message) == framework + " 测试运行在 120 秒后超时。")
            #expect(english.error(message) == message)
        }
        let diagnostic = "Maven: module/pom.xml 100% complete"
        #expect(chinese.error(diagnostic) == diagnostic)
    }
}
