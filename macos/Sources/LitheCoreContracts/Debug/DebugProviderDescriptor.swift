import Foundation

/// Debug-owned projection of language catalog metadata. DAP orchestration
/// needs file matching and a stable adapter ID, not the Language module's
/// provider runtime or LSP capability graph.
public struct DebugProviderDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let fileExtensions: Set<String>
    public let fileNames: Set<String>
    public let fileNamePrefixes: Set<String>

    public init(
        id: String,
        displayName: String,
        fileExtensions: Set<String>,
        fileNames: Set<String> = [],
        fileNamePrefixes: Set<String> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtensions = fileExtensions
        self.fileNames = fileNames
        self.fileNamePrefixes = fileNamePrefixes
    }

    public func matches(_ fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent.lowercased()
        if fileNames.contains(name) { return true }
        if fileNamePrefixes.contains(where: name.hasPrefix) { return true }
        return fileExtensions.contains(fileURL.pathExtension.lowercased())
    }
}

public enum DebugProviderError: LocalizedError, Equatable, Sendable {
    case noProvider(fileExtension: String)
    case adapterUnavailable(String)
    case capabilityUnavailable(provider: String, capability: String)

    public var errorDescription: String? {
        switch self {
        case .noProvider(let fileExtension):
            "No debug provider handles .\(fileExtension) files."
        case .adapterUnavailable(let provider):
            "\(provider) debug adapter is unavailable."
        case .capabilityUnavailable(let provider, let capability):
            "The \(provider) debug provider does not support \(capability)."
        }
    }
}
