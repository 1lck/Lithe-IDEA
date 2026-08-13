import Foundation

enum LanguageFeature: Hashable, Sendable {
    case completion
    case hover
    case navigation(method: String)
}

struct LanguageFeatureProviderPriority: RawRepresentable, Comparable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let builtin = Self(rawValue: 0)
    static let projectSymbols = Self(rawValue: 100)
    static let languageServer = Self(rawValue: 200)

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct LanguageFeatureRequestContext: Sendable {
    let fileURL: URL
    let text: String
    let position: LanguageServerPosition
    let languageID: String?
    let workspaceURL: URL?

    init(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        languageID: String? = nil,
        workspaceURL: URL? = nil
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.text = text
        self.position = position
        self.languageID = languageID
        self.workspaceURL = workspaceURL?.standardizedFileURL
    }
}

@MainActor
protocol LanguageFeatureProvider: AnyObject {
    var id: String { get }
    var priority: LanguageFeatureProviderPriority { get }

    func supports(_ feature: LanguageFeature, in context: LanguageFeatureRequestContext) -> Bool
    func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws
    func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws
    func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws
}

@MainActor
final class BuiltinLanguageFeatureProvider: LanguageFeatureProvider {
    let id = "builtin"
    let priority: LanguageFeatureProviderPriority = .builtin

    private let core: RustCoreBridge

    init(core: RustCoreBridge = RustCoreBridge()) {
        self.core = core
    }

    func supports(_ feature: LanguageFeature, in context: LanguageFeatureRequestContext) -> Bool {
        switch feature {
        case .completion:
            return core.isAvailable || Self.keywordLanguage(for: context) != nil
        case .hover, .navigation:
            return core.isAvailable
        }
    }

    func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        let symbols = core.isAvailable
            ? core.builtinLanguageCompletions(
                fileURL: context.fileURL,
                text: context.text,
                position: context.position
            ) ?? []
            : []
        let keywords = Self.keywordCompletions(in: context)

        var seenLabels = Set<String>()
        let merged = (symbols + keywords).filter { seenLabels.insert($0.label).inserted }
        completion(.success(merged))
    }

    func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        completion(.success(
            core.isAvailable
                ? core.builtinLanguageHover(
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position
                )
                : nil
        ))
    }

    func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        completion(.success(
            core.isAvailable
                ? core.builtinLanguageNavigation(
                    method: method,
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position
                ) ?? []
                : []
        ))
    }
}

@MainActor
final class LanguageServerFeatureProvider: LanguageFeatureProvider {
    let id: String
    let priority: LanguageFeatureProviderPriority = .languageServer

    private let session: any LanguageServerSession
    private(set) var features: LanguageServerFeatureSet

    init(
        providerID: String,
        session: any LanguageServerSession,
        features: LanguageServerFeatureSet = []
    ) {
        id = "lsp:\(providerID)"
        self.session = session
        self.features = features
    }

    func updateFeatures(_ features: LanguageServerFeatureSet) {
        self.features = features
    }

    func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
        guard session.isRunning else { return false }
        switch feature {
        case .completion:
            return features.contains(.completion)
        case .hover:
            return features.contains(.hover)
        case .navigation(let method):
            return features.contains(Self.navigationFeature(for: method))
        }
    }

    func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        try session.completions(
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        try session.hover(
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        try session.navigate(
            method: method,
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    private static func navigationFeature(for method: String) -> LanguageServerFeatureSet {
        switch method {
        case "textDocument/references": .references
        case "textDocument/implementation": .implementation
        default: .definition
        }
    }
}

private extension BuiltinLanguageFeatureProvider {
    enum KeywordLanguage {
        case go
        case swift
        case rust
        case python
        case javaScript
        case typeScript

        var displayName: String {
            switch self {
            case .go: "Go"
            case .swift: "Swift"
            case .rust: "Rust"
            case .python: "Python"
            case .javaScript: "JavaScript"
            case .typeScript: "TypeScript"
            }
        }

        var keywords: Set<String> {
            switch self {
            case .go:
                return [
                    "break", "case", "chan", "const", "continue", "default", "defer", "else",
                    "fallthrough", "for", "func", "go", "goto", "if", "import", "interface",
                    "map", "package", "range", "return", "select", "struct", "switch", "type", "var"
                ]
            case .swift:
                return [
                    "actor", "any", "as", "associatedtype", "async", "await", "break", "case",
                    "catch", "class", "continue", "convenience", "default", "defer", "deinit", "didSet",
                    "distributed", "do", "dynamic", "else", "enum", "extension", "fallthrough", "fileprivate",
                    "final", "for", "func", "get", "guard", "if", "import", "in", "indirect", "infix",
                    "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating",
                    "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package",
                    "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat", "required",
                    "rethrows", "return", "set", "some", "static", "struct", "subscript", "super", "switch",
                    "throws", "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet"
                ]
            case .rust:
                return [
                    "Self", "abstract", "as", "async", "await", "become", "box", "break", "const", "continue",
                    "crate", "do", "dyn", "else", "enum", "extern", "false", "final", "fn", "for", "gen",
                    "if", "impl", "in", "let", "loop", "macro", "match", "mod", "move", "mut", "override",
                    "priv", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true",
                    "try", "type", "typeof", "union", "unsafe", "unsized", "use", "virtual", "where", "while", "yield"
                ]
            case .python:
                return [
                    "False", "None", "True", "and", "as", "assert", "async", "await", "break", "case",
                    "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from",
                    "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass",
                    "raise", "return", "try", "while", "with", "yield"
                ]
            case .javaScript:
                return Self.javaScriptKeywords
            case .typeScript:
                return Self.javaScriptKeywords.union([
                    "abstract", "any", "as", "asserts", "bigint", "boolean", "constructor", "declare", "enum",
                    "from", "get", "implements", "infer", "interface", "is", "keyof", "module", "namespace",
                    "never", "number", "object", "override", "private", "protected", "public", "readonly", "require",
                    "set", "string", "symbol", "type", "undefined", "unique", "unknown"
                ])
            }
        }

        private static let javaScriptKeywords: Set<String> = [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
            "delete", "do", "else", "export", "extends", "false", "finally", "for", "function", "if", "import",
            "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this",
            "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield"
        ]
    }

    static func keywordLanguage(for context: LanguageFeatureRequestContext) -> KeywordLanguage? {
        if let languageID = context.languageID?.lowercased() {
            switch languageID {
            case "go", "golang": return .go
            case "swift": return .swift
            case "rust": return .rust
            case "python": return .python
            case "javascript", "javascriptreact", "jsx": return .javaScript
            case "typescript", "typescriptreact", "tsx": return .typeScript
            default: break
            }
        }

        switch context.fileURL.pathExtension.lowercased() {
        case "go": return .go
        case "swift": return .swift
        case "rs": return .rust
        case "py", "pyw": return .python
        case "js", "jsx", "mjs", "cjs": return .javaScript
        case "ts", "tsx", "mts", "cts": return .typeScript
        default: return nil
        }
    }

    static func keywordCompletions(
        in context: LanguageFeatureRequestContext
    ) -> [LanguageServerCompletionItem] {
        guard let language = keywordLanguage(for: context) else { return [] }
        let prefix = identifierPrefix(in: context.text, at: context.position)
        let startColumn = max(0, context.position.utf16Column - prefix.utf16.count)
        let editRange = LanguageServerRange(
            start: LanguageServerPosition(line: context.position.line, utf16Column: startColumn),
            end: context.position
        )

        return language.keywords
            .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
            .sorted()
            .map { keyword in
                LanguageServerCompletionItem(
                    label: keyword,
                    detail: "\(language.displayName) keyword",
                    documentation: nil,
                    insertText: keyword,
                    sortText: "zz_keyword_\(keyword)",
                    filterText: keyword,
                    kind: 14,
                    textEdit: LanguageServerTextEdit(range: editRange, newText: keyword),
                    additionalTextEdits: [],
                    data: nil
                )
            }
    }

    static func identifierPrefix(in text: String, at position: LanguageServerPosition) -> String {
        guard position.line >= 0, position.utf16Column >= 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard position.line < lines.count else { return "" }

        let line = lines[position.line]
        let utf16 = line.utf16
        guard position.utf16Column <= utf16.count else { return "" }
        let utf16Index = utf16.index(utf16.startIndex, offsetBy: position.utf16Column)
        guard let cursor = String.Index(utf16Index, within: line) else { return "" }

        var start = cursor
        while start > line.startIndex {
            let previous = line.index(before: start)
            guard isIdentifierCharacter(line[previous]) else { break }
            start = previous
        }
        return String(line[start..<cursor])
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }
}
