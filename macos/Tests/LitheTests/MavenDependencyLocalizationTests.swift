import Foundation
import Testing
@testable import Lithe

@MainActor
struct MavenDependencyLocalizationTests {
    private func localization(_ language: AppLanguage) throws -> MavenDependencyLocalization {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        return MavenDependencyLocalization(language: language, resourceBundle: try #require(Bundle(url: resources)))
    }

    @Test
    func dependencyStatesFollowSelectedLanguageWithoutChangingSystemLocale() throws {
        let chinese = try localization(.simplifiedChinese)
        let english = try localization(.english)
        let expected = [
            "Source Roots": "源码目录",
            "main Java": "主代码",
            "main resources": "主资源",
            "test Java": "测试代码",
            "test resources": "测试资源",
            "generated main": "生成的主代码",
            "generated test": "生成的测试代码",
            "Dependencies": "依赖",
            "Open pom.xml": "打开 pom.xml",
            "Execute Maven Goal": "执行 Maven 目标",
            "Test": "测试",
            "Resolving dependencies...": "正在解析依赖…",
            "Dependency resolution cancelled": "依赖解析已取消",
            "No dependencies": "无依赖",
            "Cancel": "取消",
            "Retry": "重试",
            "Open module pom.xml": "打开所属模块的 pom.xml"
        ]
        for (key, translation) in expected {
            #expect(chinese.text(key) == translation)
            #expect(english.text(key) == key)
        }
    }

    @Test
    func dependencyFailureTranslationPreservesExitCodesAndOriginalDetails() throws {
        let chinese = try localization(.simplifiedChinese)
        #expect(chinese.error("Maven dependency resolution timed out after 60 seconds.")
                == "Maven 依赖解析在 60 秒后超时。")
        #expect(chinese.error("Maven dependency resolution exited with code -9.")
                == "Maven 依赖解析已退出，退出码为 -9。")
        let detail = "Access denied: module/pom.xml (100% complete)"
        #expect(chinese.error("Unable to start Maven dependency resolution: " + detail)
                == "无法启动 Maven 依赖解析：" + detail)
        #expect(chinese.error(detail) == detail)
        let english = try localization(.english)
        #expect(english.error("Unable to start Maven dependency resolution: " + detail)
                == "Unable to start Maven dependency resolution: " + detail)
    }

    @Test
    func dependencyConflictTranslationPreservesMavenCoordinates() throws {
        let chinese = try localization(.simplifiedChinese)
        let english = try localization(.english)
        let dependency = MavenDependency(
            modulePath: ".", groupID: "org.example", artifactID: "demo", version: "1.0",
            type: "jar", classifier: "tests", scope: "test", resolution: .omittedConflict,
            selectedVersion: "2.0", children: []
        )
        #expect(chinese.subtitle(dependency) == "org.example:1.0:jar:tests [test]（版本冲突 → 2.0）")
        #expect(english.subtitle(dependency) == "org.example:1.0:jar:tests [test] (conflict -> 2.0)")
    }
}
