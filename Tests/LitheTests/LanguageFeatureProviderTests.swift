import Foundation
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

    @Test
    func managerContinuesCompletionAfterProviderFailure() throws {
        let manager = LanguageToolingSessionManager(languageFeatureProviders: [
            FailingFeatureProvider(mode: .callback),
            FallbackFeatureProvider()
        ])
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        var result: Result<[LanguageServerCompletionItem], Error>?

        try manager.completions(
            fileURL: fileURL,
            text: "fa",
            position: LanguageServerPosition(line: 0, utf16Column: 2),
            rootURL: fileURL.deletingLastPathComponent()
        ) { result = $0 }

        let items = try #require(result).get()
        #expect(items.contains { $0.label == "fallbackCompletion" })
        #expect(manager.languageServerLogs.first?.providerID == "test")
        #expect(manager.languageServerLogs.first?.level == .warning)
    }

    @Test
    func managerContinuesHoverAfterProviderThrow() throws {
        let manager = LanguageToolingSessionManager(languageFeatureProviders: [
            FailingFeatureProvider(mode: .throwing),
            FallbackFeatureProvider()
        ])
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        var result: Result<LanguageServerHover?, Error>?

        try manager.hover(
            fileURL: fileURL,
            text: "fallbackSymbol",
            position: LanguageServerPosition(line: 0, utf16Column: 3),
            rootURL: fileURL.deletingLastPathComponent()
        ) { result = $0 }

        let hover = try #require(result).get()
        #expect(hover?.contents == "fallback hover")
    }

    @Test
    func managerContinuesNavigationAfterProviderFailure() throws {
        let manager = LanguageToolingSessionManager(languageFeatureProviders: [
            FailingFeatureProvider(mode: .callback),
            FallbackFeatureProvider()
        ])
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        var result: Result<[LanguageServerLocation], Error>?

        try manager.navigate(
            method: "textDocument/definition",
            fileURL: fileURL,
            text: "fallbackSymbol",
            position: LanguageServerPosition(line: 0, utf16Column: 3),
            rootURL: fileURL.deletingLastPathComponent()
        ) { result = $0 }

        let locations = try #require(result).get()
        #expect(locations.map(\.url) == [fileURL])
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

private enum FeatureProviderTestError: LocalizedError {
    case failed

    var errorDescription: String? { "Test provider failed" }
}

@MainActor
private final class FailingFeatureProvider: LanguageFeatureProvider {
    enum Mode {
        case callback
        case throwing
    }

    let id = "lsp:test"
    let priority: LanguageFeatureProviderPriority = .languageServer
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func supports(_: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool { true }

    func completions(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        try fail(completion)
    }

    func hover(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        try fail(completion)
    }

    func navigate(
        method _: String,
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        try fail(completion)
    }

    private func fail<Value>(
        _ completion: @escaping (Result<Value, Error>) -> Void
    ) throws {
        switch mode {
        case .callback:
            completion(.failure(FeatureProviderTestError.failed))
        case .throwing:
            throw FeatureProviderTestError.failed
        }
    }
}

@MainActor
private final class FallbackFeatureProvider: LanguageFeatureProvider {
    let id = "test.fallback"
    let priority: LanguageFeatureProviderPriority = .projectSymbols

    func supports(_: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool { true }

    func completions(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        completion(.success([
            LanguageServerCompletionItem(
                label: "fallbackCompletion",
                detail: "Project symbols",
                documentation: nil,
                insertText: "fallbackCompletion",
                sortText: nil,
                filterText: nil,
                kind: nil,
                textEdit: nil,
                additionalTextEdits: [],
                data: nil
            )
        ]))
    }

    func hover(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        completion(.success(LanguageServerHover(
            contents: "fallback hover",
            isMarkdown: false,
            range: nil
        )))
    }

    func navigate(
        method _: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        let position = LanguageServerPosition(line: 0, utf16Column: 0)
        completion(.success([
            LanguageServerLocation(
                url: context.fileURL,
                range: LanguageServerRange(start: position, end: position)
            )
        ]))
    }
}

@MainActor
private final class CompletionFeatureProvider: LanguageFeatureProvider {
    let id = "test.remote"
    let priority: LanguageFeatureProviderPriority = .languageServer
    private let items: [LanguageServerCompletionItem]

    init(items: [LanguageServerCompletionItem]) {
        self.items = items
    }

    func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
        feature == .completion
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
