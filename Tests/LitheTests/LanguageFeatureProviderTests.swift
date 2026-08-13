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

    @Test
    func projectSymbolsUseWorkspaceIndexAndPreserveUTF16Columns() async throws {
        let rootURL = URL(fileURLWithPath: "/workspace")
        let currentURL = rootURL.appendingPathComponent("Sources/Current.swift")
        let otherURL = rootURL.appendingPathComponent("Sources/Other.swift")
        let operations = ProjectSymbolTestWorkspaceOperations(
            results: [
                FileSearchResult(url: otherURL, line: 1, preview: "let 变量 = 2")
            ],
            files: ["Sources/Other.swift": "😀 let 变量 = 2\n"]
        )
        let provider = ProjectSymbolFeatureProvider(
            operations: operations,
            visibilityRules: { .default }
        )
        let context = LanguageFeatureRequestContext(
            fileURL: currentURL,
            text: "😀 let 变量 = 1\nprint(变量)",
            position: LanguageServerPosition(line: 0, utf16Column: 8),
            workspaceURL: rootURL
        )

        let locations = try await withCheckedThrowingContinuation { continuation in
            do {
                try provider.navigate(method: "textDocument/references", in: context) {
                    continuation.resume(with: $0)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }

        #expect(locations.count == 3)
        #expect(locations.contains {
            $0.url == currentURL && $0.range.start == LanguageServerPosition(line: 0, utf16Column: 7)
        })
        #expect(locations.contains {
            $0.url == currentURL && $0.range.start == LanguageServerPosition(line: 1, utf16Column: 6)
        })
        #expect(locations.contains {
            $0.url == otherURL && $0.range.start == LanguageServerPosition(line: 0, utf16Column: 7)
        })
    }

    @Test
    func managerPublishesProjectCandidatesBeforeLSPAndCachesSemanticResult() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let projectLocation = Self.location(fileURL, line: 4)
        let semanticLocation = Self.location(fileURL, line: 9)
        let project = NavigationFeatureProvider(
            id: "project-symbols",
            priority: .projectSymbols,
            locations: [projectLocation]
        )
        let lsp = NavigationFeatureProvider(
            id: "lsp:test",
            priority: .languageServer,
            locations: [semanticLocation],
            delayMilliseconds: 30
        )
        let manager = LanguageToolingSessionManager(languageFeatureProviders: [project, lsp])
        var provisionalValues: [[LanguageServerLocation]] = []

        let first = try await navigate(
            with: manager,
            fileURL: fileURL,
            provisional: { provisionalValues.append($0) }
        )
        let second = try await navigate(with: manager, fileURL: fileURL)

        #expect(provisionalValues == [[projectLocation]])
        #expect(first == [semanticLocation])
        #expect(second == [semanticLocation])
        #expect(project.navigationRequestCount == 1)
        #expect(lsp.navigationRequestCount == 1)
        #expect(manager.languageServerLogs.contains {
            $0.detail?.contains("source=cache") == true
        })
    }

    @Test
    func managerCachesProjectFallbackWhenLanguageServerHasNoResult() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let projectLocation = Self.location(fileURL, line: 4)
        let project = NavigationFeatureProvider(
            id: "project-symbols",
            priority: .projectSymbols,
            locations: [projectLocation]
        )
        let lsp = NavigationFeatureProvider(
            id: "lsp:test",
            priority: .languageServer,
            locations: []
        )
        let manager = LanguageToolingSessionManager(languageFeatureProviders: [project, lsp])

        let first = try await navigate(with: manager, fileURL: fileURL)
        let second = try await navigate(with: manager, fileURL: fileURL)

        #expect(first == [projectLocation])
        #expect(second == [projectLocation])
        #expect(project.navigationRequestCount == 1)
        #expect(lsp.navigationRequestCount == 1)
        #expect(manager.languageServerLogs.contains {
            $0.detail?.contains("source=cache") == true
        })
    }

    @Test
    func managerCoalescesIdenticalNavigationRequestsInFlight() async throws {
        let fileURL = URL(fileURLWithPath: "/tmp/main.go")
        let semanticLocation = Self.location(fileURL, line: 9)
        let lsp = NavigationFeatureProvider(
            id: "lsp:test",
            priority: .languageServer,
            locations: [semanticLocation],
            delayMilliseconds: 30
        )
        let manager = LanguageToolingSessionManager(languageFeatureProviders: [lsp])

        async let first = navigate(with: manager, fileURL: fileURL)
        async let second = navigate(with: manager, fileURL: fileURL)
        let values = try await (first, second)

        #expect(values.0 == [semanticLocation])
        #expect(values.1 == [semanticLocation])
        #expect(lsp.navigationRequestCount == 1)
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

    private static func location(_ url: URL, line: Int) -> LanguageServerLocation {
        let position = LanguageServerPosition(line: line, utf16Column: 0)
        return LanguageServerLocation(
            url: url,
            range: LanguageServerRange(start: position, end: position)
        )
    }

    private func navigate(
        with manager: LanguageToolingSessionManager,
        fileURL: URL,
        provisional: (([LanguageServerLocation]) -> Void)? = nil
    ) async throws -> [LanguageServerLocation] {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try manager.navigate(
                    method: "textDocument/references",
                    fileURL: fileURL,
                    text: "target",
                    position: LanguageServerPosition(line: 0, utf16Column: 2),
                    rootURL: fileURL.deletingLastPathComponent(),
                    provisional: provisional
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private struct ProjectSymbolTestWorkspaceOperations: WorkspaceOperations {
    let results: [FileSearchResult]
    let files: [String: String]

    func snapshot(at _: URL, visibilityRules _: FileVisibilityRules) -> WorkspaceSnapshot? { nil }
    func search(
        at _: URL,
        query _: String,
        options _: ProjectSearchOptions,
        visibilityRules _: FileVisibilityRules
    ) -> [FileSearchResult]? { results }
    func searchEverywhere(
        at _: URL,
        query _: String,
        options _: ProjectSearchOptions,
        visibilityRules _: FileVisibilityRules
    ) -> SearchEverywhereResults? { nil }
    func previewReplacement(
        at _: URL,
        query _: String,
        replacement _: String,
        options _: ProjectSearchOptions,
        paths _: [String],
        textOverrides _: [String: String],
        visibilityRules _: FileVisibilityRules
    ) -> [ProjectReplacementFile]? { nil }
    func readFile(at _: URL, relativePath: String) -> String? { files[relativePath] }
    func writeFile(_: String, at _: URL, relativePath _: String) -> Bool { false }
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

@MainActor
private final class NavigationFeatureProvider: LanguageFeatureProvider {
    let id: String
    let priority: LanguageFeatureProviderPriority
    private let locations: [LanguageServerLocation]
    private let delayMilliseconds: Int
    private(set) var navigationRequestCount = 0

    init(
        id: String,
        priority: LanguageFeatureProviderPriority,
        locations: [LanguageServerLocation],
        delayMilliseconds: Int = 0
    ) {
        self.id = id
        self.priority = priority
        self.locations = locations
        self.delayMilliseconds = delayMilliseconds
    }

    func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
        if case .navigation = feature { return true }
        return false
    }

    func completions(
        in _: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        completion(.success([]))
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
        navigationRequestCount += 1
        let locations = locations
        guard delayMilliseconds > 0 else {
            completion(.success(locations))
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            completion(.success(locations))
        }
    }
}
