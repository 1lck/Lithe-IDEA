import Foundation
import Testing
@testable import Lithe

/// Protects the settings sidebar search vocabulary.
///
/// A page's search terms are the only way settings search can reach it, and a
/// missing term fails silently: the page simply cannot be found. The Editor page
/// lost its tabs entry while it gained the programming-font row, so these tests
/// pin both halves of the match — the English key and its shipped translation.
@Suite("Settings search vocabulary")
@MainActor
struct SettingsSearchVocabularyTests {
    @Test func everySettingsPageKeepsSearchTerms() {
        for category in SettingsCategory.allCases {
            #expect(
                !SettingsSearchVocabulary.terms(for: category).isEmpty,
                "\(category.rawValue) must stay reachable from settings search"
            )
        }
    }

    @Test func editorPageKeepsTabsAndProgrammingFontTerms() {
        let terms = SettingsSearchVocabulary.terms(for: .editor)

        for expected in ["Editor", "Display", "Editor tabs", "tabs", "Font", "Font size", "Search fonts", "Tab width", "Indentation"] {
            #expect(terms.contains(expected), "Editor search must keep matching \(expected)")
        }
        #expect(terms.count == Set(terms).count, "duplicate search terms add nothing: \(terms)")
    }

    @Test func editorPageMatchesTabsQueriesAgain() {
        // The regression that removed "Editor tabs" made these queries fall
        // through, so the Editor page could no longer be opened by search.
        #expect(SettingsSearchVocabulary.matches(query: "Editor tabs", category: .editor))
        #expect(SettingsSearchVocabulary.matches(query: "tabs", category: .editor))
        #expect(SettingsSearchVocabulary.matches(query: "tab", category: .editor))
    }

    @Test func agentManagementPageIsSearchableSeparatelyFromAIProviders() {
        #expect(SettingsSearchVocabulary.matches(query: "ACP adapter", category: .agents))
        #expect(SettingsSearchVocabulary.matches(query: "Codex", category: .agents))
        #expect(!SettingsSearchVocabulary.matches(query: "ACP adapter", category: .providers))
    }

    @Test func editorPageMatchesTheNewFontQueries() {
        #expect(SettingsSearchVocabulary.matches(query: "font", category: .editor))
        #expect(SettingsSearchVocabulary.matches(query: "fonts", category: .editor))
        #expect(SettingsSearchVocabulary.matches(query: "Search fonts", category: .editor))
        // Terms stay case- and whitespace-insensitive like the sidebar filter.
        #expect(SettingsSearchVocabulary.matches(query: "  FONT  ", category: .editor))
        #expect(!SettingsSearchVocabulary.matches(query: "menlo", category: .editor))
    }

    @Test func logsAndDiagnosticsShareOneSearchableToolsPage() throws {
        let translations = try simplifiedChineseTranslations()
        for query in ["Logs", "Log directory", "Log timeline", "Detailed diagnostics", "日志", "日志目录", "详细诊断"] {
            #expect(SettingsSearchVocabulary.matches(query: query, category: .diagnostics, localize: { translations[$0] ?? $0 }))
            #expect(!SettingsSearchVocabulary.matches(query: query, category: .general, localize: { translations[$0] ?? $0 }))
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/fixtures/diagnostics/logging-ui-v1.json"))) as? [String: Any])
        let navigation = try #require(fixture["navigation"] as? [String: String])
        #expect(SettingsCategory.diagnostics.title == navigation["title"])
        #expect(SettingsCategory.diagnostics.group?.rawValue == navigation["group"])
        #expect(SettingsCategory.diagnostics.rawValue == navigation["macosCategory"])
        #expect(SettingsCategory.diagnostics.group == .tools)
        #expect(SettingsCategory.diagnostics.rawValue == "Diagnostics", "Existing navigation identifiers remain compatible")
    }

    @Test func emptyQueryMatchesEveryPage() {
        for category in SettingsCategory.allCases {
            #expect(SettingsSearchVocabulary.matches(query: "", category: category))
            #expect(SettingsSearchVocabulary.matches(query: "   ", category: category))
        }
    }

    /// The scrollback row initially shipped with "Scrollback lines" as its only
    /// new term, so the label the page actually shows — "Terminal scrollback" —
    /// could not find the page, neither in English nor in its translation.
    @Test func terminalPageMatchesTheScrollbackQueries() {
        #expect(SettingsSearchVocabulary.matches(query: "Scrollback", category: .terminal))
        #expect(SettingsSearchVocabulary.matches(query: "Scrollback lines", category: .terminal))
        #expect(SettingsSearchVocabulary.matches(query: "Terminal scrollback", category: .terminal))
    }

    @Test func simplifiedChineseScrollbackQueriesFindTheTerminalPage() throws {
        let translations = try simplifiedChineseTranslations()
        let localize: (String) -> String = { translations[$0] ?? $0 }

        #expect(translations["Terminal scrollback"] == "终端回滚行数")

        #expect(SettingsSearchVocabulary.matches(query: "终端回滚行数", category: .terminal, localize: localize))
        #expect(SettingsSearchVocabulary.matches(query: "回滚行数", category: .terminal, localize: localize))
        #expect(SettingsSearchVocabulary.matches(query: "回滚", category: .terminal, localize: localize))
        #expect(SettingsSearchVocabulary.matches(query: "行数", category: .terminal, localize: localize))
        #expect(!SettingsSearchVocabulary.matches(query: "终端回滚行数", category: .editor, localize: localize))
    }

    /// The visible Chinese label must keep its English key, otherwise typing what
    /// the user actually reads cannot find the page.
    @Test func simplifiedChineseLabelsStillFindTheirPages() throws {
        let translations = try simplifiedChineseTranslations()
        let localize: (String) -> String = { translations[$0] ?? $0 }

        #expect(translations["Editor tabs"] == "编辑器标签栏")
        #expect(translations["Font"] == "字体")
        #expect(translations["Search fonts"] == "搜索字体")

        #expect(SettingsSearchVocabulary.matches(query: "编辑器标签栏", category: .editor, localize: localize))
        #expect(SettingsSearchVocabulary.matches(query: "标签栏", category: .editor, localize: localize))
        #expect(SettingsSearchVocabulary.matches(query: "字体", category: .editor, localize: localize))
        #expect(SettingsSearchVocabulary.matches(query: "搜索字体", category: .editor, localize: localize))
        #expect(SettingsSearchVocabulary.matches(query: "缩进", category: .editor, localize: localize))
        #expect(!SettingsSearchVocabulary.matches(query: "字体", category: .terminal, localize: localize))
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
