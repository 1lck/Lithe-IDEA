import Foundation
import LitheCoreContracts

struct UnavailableBuiltinLanguageFeatureCore: BuiltinLanguageFeatureCore {
    var isBuiltinLanguageFeatureAvailable: Bool { false }

    func builtinLanguageCompletions(
        fileURL _: URL,
        text _: String,
        position _: LanguageServerPosition
    ) -> [LanguageServerCompletionItem]? { nil }

    func builtinLanguageHover(
        fileURL _: URL,
        text _: String,
        position _: LanguageServerPosition
    ) -> LanguageServerHover? { nil }

    func builtinLanguageNavigation(
        method _: String,
        fileURL _: URL,
        text _: String,
        position _: LanguageServerPosition
    ) -> [LanguageServerLocation]? { nil }
}

package enum LanguageFeature: Hashable, Sendable {
    case completion
    case hover
    case navigation(method: String)
}

package struct LanguageFeatureProviderPriority: RawRepresentable, Comparable, Hashable, Sendable {
    package let rawValue: Int

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }

    package static let builtin = Self(rawValue: 0)
    package static let projectSymbols = Self(rawValue: 100)
    package static let languageServer = Self(rawValue: 200)

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package struct LanguageFeatureRequestContext: Sendable {
    package let fileURL: URL
    package let text: String
    package let position: LanguageServerPosition
    package let languageID: String?
    package let workspaceURL: URL?
    package let completionContext: LanguageServerCompletionContext?

    package init(
        fileURL: URL,
        text: String,
        position: LanguageServerPosition,
        languageID: String? = nil,
        workspaceURL: URL? = nil,
        completionContext: LanguageServerCompletionContext? = nil
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.text = text
        self.position = position
        self.languageID = languageID
        self.workspaceURL = workspaceURL?.standardizedFileURL
        self.completionContext = completionContext
    }
}

@MainActor
package protocol LanguageFeatureProvider: AnyObject {
    var id: String { get }
    var priority: LanguageFeatureProviderPriority { get }

    func supports(_ feature: LanguageFeature, in context: LanguageFeatureRequestContext) -> Bool
    func completionList(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void
    ) throws
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

package extension LanguageFeatureProvider {
    func completionList(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void
    ) throws {
        try completions(in: context) { completion($0.map { LanguageServerCompletionList(items: $0) }) }
    }
}

@MainActor
package final class BuiltinLanguageFeatureProvider: LanguageFeatureProvider {
    package let id = "builtin"
    package let priority: LanguageFeatureProviderPriority = .builtin

    private let core: any BuiltinLanguageFeatureCore

    package init(core: any BuiltinLanguageFeatureCore) {
        self.core = core
    }

    package convenience init() {
        self.init(core: UnavailableBuiltinLanguageFeatureCore())
    }

    package func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
        switch feature {
        case .completion, .hover, .navigation:
            return core.isBuiltinLanguageFeatureAvailable
        }
    }

    package func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        // Language keywords come from the language server or plugin; the
        // fallback only offers current-file identifiers computed by Core.
        completion(.success(
            core.isBuiltinLanguageFeatureAvailable
                ? core.builtinLanguageCompletions(
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position
                ) ?? []
                : []
        ))
    }

    package func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        completion(.success(
            core.isBuiltinLanguageFeatureAvailable
                ? core.builtinLanguageHover(
                    fileURL: context.fileURL,
                    text: context.text,
                    position: context.position
                )
                : nil
        ))
    }

    package func navigate(
        method: String,
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerLocation], Error>) -> Void
    ) throws {
        completion(.success(
            core.isBuiltinLanguageFeatureAvailable
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
package final class LanguageServerFeatureProvider: LanguageFeatureProvider {
    package let id: String
    package let priority: LanguageFeatureProviderPriority = .languageServer

    private let session: any LanguageServerSession
    private(set) var features: LanguageServerFeatureSet

    package init(
        providerID: String,
        session: any LanguageServerSession,
        features: LanguageServerFeatureSet = []
    ) {
        id = "lsp:\(providerID)"
        self.session = session
        self.features = features
    }

    package func updateFeatures(_ features: LanguageServerFeatureSet) {
        self.features = features
    }

    package func supports(_ feature: LanguageFeature, in _: LanguageFeatureRequestContext) -> Bool {
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

    package func completionList(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerCompletionList, Error>) -> Void
    ) throws {
        try session.completionList(fileURL: context.fileURL, position: context.position,
                                   context: context.completionContext, completion: completion)
    }

    package func completions(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<[LanguageServerCompletionItem], Error>) -> Void
    ) throws {
        try session.completions(
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    package func hover(
        in context: LanguageFeatureRequestContext,
        completion: @escaping (Result<LanguageServerHover?, Error>) -> Void
    ) throws {
        try session.hover(
            fileURL: context.fileURL,
            position: context.position,
            completion: completion
        )
    }

    package func navigate(
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
