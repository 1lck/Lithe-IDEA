import Foundation
import LitheCoreContracts
import LitheLanguageIntelligenceModule
import Testing
@testable import Lithe

@Suite("Language feature providers")
@MainActor
struct LanguageFeatureProviderTests {
    /// LSP-09: keywords belong to the language server or plugin, so the
    /// fallback provider no longer carries a private per-language keyword table.
    @Test
    func builtinFallbackDoesNotSupplyLanguageKeywords() {
        let provider = BuiltinLanguageFeatureProvider()
        let context = LanguageFeatureRequestContext(
            fileURL: URL(fileURLWithPath: "/tmp/main.go"),
            text: "fu",
            position: LanguageServerPosition(line: 0, utf16Column: 2),
            languageID: "go"
        )
        #expect(!provider.supports(.completion, in: context))
    }

    /// LSP-09: overloads that share a label survive, while a lower-priority
    /// provider's duplicate label is shadowed by the server candidate.
    @Test
    func managerKeepsOverloadsAndShadowsLowerPriorityLabels() throws {
        let remote = CompletionFeatureProvider(items: [
            Self.item(label: "format", detail: "LSP"),
            Self.item(label: "print", detail: "print(String)"),
            Self.item(label: "print", detail: "print(int)")
        ])
        let fallback = CompletionFeatureProvider(id: "test.fallback", priority: .builtin, items: [
            Self.item(label: "format", detail: "fallback"),
            Self.item(label: "fmt", detail: "fallback")
        ])
        let manager = LanguageToolingSessionManager(
            policyCore: RustCoreBridge(),
            languageFeatureProviders: [fallback, remote]
        )
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        var result: Result<[LanguageServerCompletionItem], Error>?

        try manager.completions(
            fileURL: fileURL,
            text: "f",
            position: LanguageServerPosition(line: 0, utf16Column: 1),
            rootURL: fileURL.deletingLastPathComponent()
        ) { result = $0 }

        let items = try #require(result).get()
        #expect(items.map(\.label) == ["format", "print", "print", "fmt"])
        #expect(items.map(\.detail) == ["LSP", "print(String)", "print(int)", "fallback"])
    }

    @Test(arguments: [true, false])
    func emptyProviderListPreservesRefreshStateWhenMergedWithFallback(incomplete: Bool) throws {
        let remote = CompletionFeatureProvider(items: [], isIncomplete: incomplete)
        let fallback = CompletionFeatureProvider(id: "test.fallback", priority: .builtin,
                                                 items: [Self.item(label: "func", detail: "fallback")])
        let manager = LanguageToolingSessionManager(policyCore: RustCoreBridge(),
                                                    languageFeatureProviders: [remote, fallback])
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        var result: Result<LanguageServerCompletionList, Error>?
        try manager.completionList(fileURL: fileURL, text: "f",
            position: .init(line: 0, utf16Column: 1), rootURL: fileURL.deletingLastPathComponent(),
            completionContext: .init(triggerKind: 3)) { result = $0 }
        let list = try #require(result).get()
        #expect(list.isIncomplete == incomplete)
        #expect(list.items.map(\.label) == ["func"])
        #expect(remote.context?.triggerKind == 3)
    }

    /// The bridge returns exactly the shared fixture responses on macOS.
    @Test
    func rustBridgeMatchesSharedActivationAndMergeFixtures() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/fixtures/lsp")
        struct ActivationCase: Decodable {
            struct Request: Decodable {
                let state: LanguageServerActivationState?
                let event: LanguageServerActivationEvent
                let nowMs: UInt64
            }
            let name: String
            let request: Request
            let response: LanguageServerActivationOutcome
        }
        struct MergeCase: Decodable {
            struct List: Decodable { let labels: [String]; let isIncomplete: Bool }
            struct Request: Decodable { let lists: [List] }
            struct Response: Decodable { let keep: [[Int]]; let isIncomplete: Bool }
            let name: String
            let request: Request
            let response: Response
        }
        struct Fixture<Case: Decodable>: Decodable { let cases: [Case] }
        let bridge = RustCoreBridge()
        let activation = try JSONDecoder().decode(Fixture<ActivationCase>.self, from: Data(
            contentsOf: fixtures.appendingPathComponent("activation-policy-v1.json")))
        for entry in activation.cases {
            let outcome = bridge.languageServerActivation(
                state: entry.request.state, event: entry.request.event, nowMs: entry.request.nowMs)
            #expect(try outcome.get() == entry.response, "\(entry.name)")
        }
        let merge = try JSONDecoder().decode(Fixture<MergeCase>.self, from: Data(
            contentsOf: fixtures.appendingPathComponent("completion-merge-v1.json")))
        for entry in merge.cases {
            let selection = try bridge.mergeCompletions(
                labels: entry.request.lists.map(\.labels), incomplete: entry.request.lists.map(\.isIncomplete)).get()
            #expect(selection.keep == entry.response.keep, "\(entry.name)")
            #expect(selection.isIncomplete == entry.response.isIncomplete, "\(entry.name)")
        }
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
    let id: String
    let priority: LanguageFeatureProviderPriority
    private let items: [LanguageServerCompletionItem]
    private let isIncomplete: Bool
    private(set) var context: LanguageServerCompletionContext?

    init(id: String = "test.remote", priority: LanguageFeatureProviderPriority = .languageServer,
         items: [LanguageServerCompletionItem], isIncomplete: Bool = false) {
        self.id = id
        self.priority = priority
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
