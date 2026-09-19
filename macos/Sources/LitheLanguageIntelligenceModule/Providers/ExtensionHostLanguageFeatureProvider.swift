import Foundation
import LitheCoreContracts

/// Adapts one VS Code language provider registration to Lithe's editor provider router.
/// The host remains the owner of extension callbacks; this type only normalizes JSON results.
@MainActor
package final class ExtensionHostLanguageFeatureProvider: LanguageFeatureProvider {
    package let id: String
    package let priority: LanguageFeatureProviderPriority = .languageServer
    private let languageIDs: Set<String>
    private let provide: @MainActor (String, LanguageFeatureRequestContext) async throws -> ToolingJSONValue
    private let kinds: Set<String>
    private let resolve: @MainActor (ToolingJSONValue, URL) async throws -> ToolingJSONValue

    package init(
        id: String,
        languageIDs: Set<String>,
        kinds: Set<String>,
        provide: @escaping @MainActor (String, LanguageFeatureRequestContext) async throws -> ToolingJSONValue,
        resolve: @escaping @MainActor (ToolingJSONValue, URL) async throws -> ToolingJSONValue
    ) {
        self.id = id
        self.languageIDs = languageIDs
        self.kinds = kinds
        self.provide = provide
        self.resolve = resolve
    }

    package func supports(_ feature: LanguageFeature, in context: LanguageFeatureRequestContext) -> Bool {
        guard languageIDs.isEmpty || languageIDs.contains("*") || languageIDs.contains(context.languageID ?? "") else { return false }
        switch feature {
        case .completion: return kinds.contains("completion")
        case .hover: return kinds.contains("hover")
        case .navigation(let method): return Self.kind(for: method).map { kinds.contains($0) } ?? false
        }
    }

    package func completions(in context: LanguageFeatureRequestContext,
                             completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void) throws {
        Task { @MainActor in
            do { completion(.success(Self.completions(try await provide("completion", context), providerID: id))) }
            catch { completion(.failure(error)) }
        }
    }

    package func resolveCompletion(_ item: LanguageServerCompletionItem, fileURL: URL,
                                   completion: @escaping (Result<LanguageServerCompletionItem, Error>) -> Void) throws {
        guard case .object(let data)? = item.data, let hostData = data["hostCompletion"] else {
            throw ExtensionHostFailure("invalidParams", "Completion item has no host identity.")
        }
        Task { @MainActor in
            do {
                let value = try await resolve(hostData, fileURL)
                guard let resolved = Self.completions(.array([value]), providerID: id).first else {
                    throw ExtensionHostFailure("invalidParams", "Extension returned an invalid completion item.")
                }
                completion(.success(resolved))
            } catch { completion(.failure(error)) }
        }
    }

    package func hover(in context: LanguageFeatureRequestContext,
                       completion: @escaping (Result<LanguageServerHover?, Error>) -> Void) throws {
        Task { @MainActor in
            do { completion(.success(Self.hover(try await provide("hover", context)))) }
            catch { completion(.failure(error)) }
        }
    }

    package func navigate(method: String, in context: LanguageFeatureRequestContext,
                          completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void) throws {
        guard let kind = Self.kind(for: method) else {
            throw ExtensionHostFailure("unsupportedApi", "Unsupported navigation method: \(method)")
        }
        Task { @MainActor in
            do { completion(.success(Self.locations(try await provide(kind, context)))) }
            catch { completion(.failure(error)) }
        }
    }

    private static func kind(for method: String) -> String? {
        switch method {
        case "textDocument/references": return "references"
        case "textDocument/implementation": return "implementation"
        case "textDocument/definition": return "definition"
        default: return nil
        }
    }

    private static func dictionary(_ value: ToolingJSONValue) -> [String: ToolingJSONValue] {
        guard case .object(let value) = value else { return [:] }
        return value
    }

    private static func string(_ value: ToolingJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private static func integer(_ value: ToolingJSONValue?) -> Int? {
        guard case .integer(let value) = value else { return nil }
        return value
    }

    private static func range(_ value: ToolingJSONValue?) -> LanguageServerRange? {
        let object = value.map(dictionary) ?? [:]
        guard let startLine = integer(object["startLine"]), let startColumn = integer(object["startColumn"]),
              let endLine = integer(object["endLine"]), let endColumn = integer(object["endColumn"]),
              startLine > 0, startColumn > 0, endLine > 0, endColumn > 0 else { return nil }
        return LanguageServerRange(
            start: LanguageServerPosition(line: startLine - 1, utf16Column: startColumn - 1),
            end: LanguageServerPosition(line: endLine - 1, utf16Column: endColumn - 1)
        )
    }

    private static func edit(_ value: ToolingJSONValue?) -> LanguageServerTextEdit? {
        let fields = value.map(dictionary) ?? [:]
        guard let range = range(fields["range"]), let text = string(fields["text"]) else { return nil }
        return LanguageServerTextEdit(range: range, newText: text)
    }

    private static func completions(_ value: ToolingJSONValue, providerID: String) -> [LanguageServerCompletionItem] {
        let object = dictionary(value)
        let values: [ToolingJSONValue]
        if case .array(let array) = object["completions"] { values = array }
        else if case .array(let array) = value { values = array }
        else { values = [] }
        return values.compactMap { item in
            let fields = dictionary(item)
            guard let label = string(fields["label"]) else { return nil }
            return LanguageServerCompletionItem(
                label: label, detail: string(fields["detail"]), documentation: string(fields["documentation"]),
                insertText: string(fields["insertText"]) ?? label, sortText: string(fields["sortText"]),
                filterText: string(fields["filterText"]), kind: integer(fields["kind"]), textEdit: edit(fields["textEdit"]),
                additionalTextEdits: { if case .array(let edits) = fields["additionalTextEdits"] { return edits.compactMap { edit($0) } }; return [] }(), data: .object(["extensionHostProvider": .string(providerID), "hostCompletion": fields["data"] ?? .null]), insertTextFormat: integer(fields["insertTextFormat"]) ?? 1
            )
        }
    }

    private static func hover(_ value: ToolingJSONValue) -> LanguageServerHover? {
        let fields = dictionary(value)
        guard let contents = string(fields["contents"]) else { return nil }
        return LanguageServerHover(contents: contents, isMarkdown: true, range: range(fields["range"]))
    }

    private static func locations(_ value: ToolingJSONValue) -> [LanguageServerLocation] {
        let values: [ToolingJSONValue]
        if case .array(let array) = value { values = array } else { values = [value] }
        return values.compactMap { item in
            let fields = dictionary(item)
            guard let uri = string(fields["uri"]), let url = URL(string: uri), let location = range(fields["range"]) else { return nil }
            return LanguageServerLocation(url: url, range: location)
        }
    }
}
