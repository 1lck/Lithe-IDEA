import Foundation
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Language feature providers")
@MainActor
struct LanguageFeatureProviderTests {
    @Test
    func builtinCompletionIncludesLanguageKeywords() throws {
        let provider = BuiltinLanguageFeatureProvider()
        let context = LanguageFeatureRequestContext(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            text: "fu",
            position: LanguageServerPosition(line: 0, utf16Column: 2),
            languageID: "go"
        )
        var result: Result<[LanguageServerCompletionItem], Error>?

        try provider.completions(in: context) { result = $0 }

        let resolved = try #require(result)
        let items = try resolved.get()
        let item = try #require(items.first { $0.label == "func" })
        #expect(item.detail == "Go keyword")
        #expect(item.textEdit?.range.start.utf16Column == 0)
        #expect(item.textEdit?.range.end.utf16Column == 2)
    }

    @Test
    func managerMergesHigherPriorityProviderWithBuiltinFallback() throws {
        let remote = CompletionFeatureProvider(items: [
            Self.item(label: "format", detail: "LSP"),
            Self.item(label: "func", detail: "LSP")
        ])
        let manager = LanguageToolingSessionManager(
            languageFeatureProviders: [remote]
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        var result: Result<[LanguageServerCompletionItem], Error>?

        try manager.completions(
            fileURL: fileURL,
            text: "f",
            position: LanguageServerPosition(line: 0, utf16Column: 1),
            rootURL: fileURL.deletingLastPathComponent()
        ) { result = $0 }

        let resolved = try #require(result)
        let items = try resolved.get()
        #expect(items.first?.label == "format")
        #expect(items.filter { $0.label == "func" }.count == 1)
        #expect(items.contains { $0.label == "for" && $0.detail == "Go keyword" })
    }

    @Test(arguments: [true, false])
    func emptyProviderListPreservesRefreshStateWhenMergedWithLocalKeywords(incomplete: Bool) throws {
        let remote = CompletionFeatureProvider(items: [], isIncomplete: incomplete)
        let manager = LanguageToolingSessionManager(languageFeatureProviders: [remote])
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        var result: Result<LanguageServerCompletionList, Error>?
        try manager.completionList(fileURL: fileURL, text: "f",
            position: .init(line: 0, utf16Column: 1), rootURL: fileURL.deletingLastPathComponent(),
            completionContext: .init(triggerKind: 3)) { result = $0 }
        let list = try #require(result).get()
        #expect(list.isIncomplete == incomplete)
        #expect(list.items.contains { $0.label == "func" })
        #expect(remote.context?.triggerKind == 3)
    }

    private static func item(label: String, detail: String) -> LanguageServerCompletionItem {
        LanguageServerCompletionItem(
            label: label,
            detail: detail,
            documentation: nil,
            insertText: label,
            sortText: nil,
            filterText: nil,
            kind: nil,
            textEdit: nil,
            additionalTextEdits: [],
            data: nil
        )
    }
}

@MainActor
private final class CompletionFeatureProvider: LanguageFeatureProvider {
    let id = "test.remote"
    let priority: LanguageFeatureProviderPriority = .languageServer
    private let items: [LanguageServerCompletionItem]
    private let isIncomplete: Bool
    private(set) var context: LanguageServerCompletionContext?

    init(items: [LanguageServerCompletionItem], isIncomplete: Bool = false) {
        self.items = items
        self.isIncomplete = isIncomplete
    }

    func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
        feature == .completion
    }

    func completionList(in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void) throws {
        self.context = context.completionContext
        completion(.success(.init(items: items, isIncomplete: isIncomplete)))
    }

    func completions(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        completion(.success(items))
    }

    func hover(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        completion(.success(nil))
    }

    func navigate(
        method _: String,
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        completion(.success([]))
    }
}
