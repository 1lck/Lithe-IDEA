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

    @Test func editorPageMatchesTheNewFontQueries() {
        #expect(SettingsSearchVocabulary.matches(query: "font", category: .editor))
        #expect(SettingsSearchVocabulary.matches(query: "fonts", category: .editor))
        #expect(SettingsSearchVocabulary.matches(query: "Search fonts", category: .editor))
        // Terms stay case- and whitespace-insensitive like the sidebar filter.
        #expect(SettingsSearchVocabulary.matches(query: "  FONT  ", category: .editor))
        #expect(!SettingsSearchVocabulary.matches(query: "menlo", category: .editor))
    }

    @Test func emptyQueryMatchesEveryPage() {
        for category in SettingsCategory.allCases {
            #expect(SettingsSearchVocabulary.matches(query: "", category: category))
            #expect(SettingsSearchVocabulary.matches(query: "   ", category: category))
        }
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
