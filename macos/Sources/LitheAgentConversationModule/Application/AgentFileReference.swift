import Foundation

/// A native file URL supplied by the user, not a copied or preloaded attachment.
public struct AgentFileReference: Identifiable, Equatable, Sendable {
    public static let maximumCount = 32
    public let url: URL
    public var id: String { url.absoluteString }
    public var name: String { url.lastPathComponent }

    public init(url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.isEmpty, url.query == nil, url.fragment == nil else {
            throw AgentFileReferenceError.invalidURL
        }
        self.url = url.standardizedFileURL
    }

    /// Preserve drop order, reject an invalid batch atomically, and bound draft size.
    public static func adding(_ urls: [URL], to existing: [Self]) throws -> [Self] {
        var result = existing
        var ids = Set(existing.map(\.id))
        for url in urls {
            let file = try Self(url: url)
            if ids.insert(file.id).inserted { result.append(file) }
            guard result.count <= maximumCount else { throw AgentFileReferenceError.tooManyFiles }
        }
        return result
    }

    var commandValue: [String: String] { ["uri": id, "name": name] }
}

public enum AgentFileReferenceError: LocalizedError {
    case invalidURL
    case tooManyFiles

    public var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "Only local files can be attached to an Agent message.")
        case .tooManyFiles: String(localized: "Attach up to 32 files per message.")
        }
    }
}

/// Keep file context with the message while a session is being created or loaded.
struct AgentPrompt {
    let text: String
    let files: [AgentFileReference]
    var isEmpty: Bool { text.isEmpty && files.isEmpty }
    var displayText: String {
        ([text].filter { !$0.isEmpty } + files.map { "📎 \($0.url.path)" }).joined(separator: "\n\n")
    }
}
