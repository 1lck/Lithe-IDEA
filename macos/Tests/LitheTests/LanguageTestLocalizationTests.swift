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
